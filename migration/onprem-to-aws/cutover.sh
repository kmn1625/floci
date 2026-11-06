#!/usr/bin/env bash
# Move the shop from onprem1 to AWS, keeping a way back. Each step prints when it ran.
#   bash cutover.sh                   the full cutover
#   SKIP_SEQUENCES=1 bash cutover.sh  the naive one, to show what breaks
#
# The freeze is on the app's role, not the database. Freezing the database also refuses the command
# that undoes it, and refuses the replication that brings writes home after a rollback.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "$0")" && pwd)
DRILL=/d/devops-project/.cache/migrate-drill
RDS=$(cat "$DRILL/rds.name")
PW=$(cat "$DRILL/repl.pw")

t0=$(date +%s.%N)
stamp() { printf '%6.1fs  %s\n' "$(python -c "import time;print(time.time()-$t0)")" "$1"; }
# Over the network, like a real operator: `multipass exec` takes seconds a call and would pad the outage.
src() {
  local out rc=1
  for _ in 1 2 3; do
    if out=$(docker exec -e PGPASSWORD="$(cat "$DRILL/admin.pw")" -e PGCONNECT_TIMEOUT=3 "$RDS" \
      psql "host=10.77.0.20 dbname=shop user=mig_admin sslmode=require" -v ON_ERROR_STOP=1 -Atqc "$1" 2>&1); then rc=0; break; fi
    case "$out" in *timeout*|*"could not connect"*) sleep 0.3 ;; *) break ;; esac
  done
  [ "$rc" = 0 ] || { echo "src failed: $out" >&2; return 1; }
  printf '%s\n' "$out"
}
dst() { docker exec "$RDS" psql -U shopadmin -d shop -v ON_ERROR_STOP=1 -Atqc "$1"; }
sync() {
  docker run --rm --network lab_default -v "D:/devops-project/floci/migration/onprem-to-aws/sync-uploads.py:/sync.py:ro" \
    -e SOURCE_URL=http://10.77.0.20:8099 -e S3_ENDPOINT=http://floci-lab:4566 -e S3_BUCKET=shop-uploads \
    -e AWS_ACCESS_KEY_ID=floci -e AWS_SECRET_ACCESS_KEY=floci \
    -e DATABASE_URL="postgresql://shop_app:$(cat "$DRILL/app.pw")@floci-lab:7002/shop" \
    --entrypoint python shop:1.0.1 /sync.py "$@"
}

stamp "before the freeze: copy and fully verify files, so the freeze only has to handle new ones"
sync --verify
dst "create publication back_pub for all tables" 2>/dev/null || true

freeze=$(date +%s.%N)
stamp "FREEZE: the app can no longer write"
src "alter role shop set default_transaction_read_only = on;"
src "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'shop'" >/dev/null

stamp "wait for the target to catch up"
want=$(src "select pg_current_wal_lsn()")
for _ in $(seq 1 120); do
  behind=$(dst "select pg_wal_lsn_diff('$want', coalesce(latest_end_lsn, '0/0')) from pg_stat_subscription where pid is not null limit 1")
  [ -n "$behind" ] && [ "${behind%.*}" -le 0 ] && break
  sleep 0.5
done
if [ -z "${behind:-}" ] || [ "${behind%.*}" -gt 0 ]; then
  echo "STOP: the target did not catch up (behind by ${behind:-unknown} bytes). Unfreeze the source: writes were not lost." >&2
  exit 1
fi
stamp "target caught up"

stamp "copy files made since the first pass"
sync --verify-new --frozen

if [ "${SKIP_SEQUENCES:-0}" = 1 ]; then
  stamp "SKIPPED: sequences left as they are on the target"
else
  stamp "copy sequences: logical replication does not"
  # Forward only: setval will happily wind a sequence back onto ids already used.
  dst "$(src "select string_agg(format('select setval(%L, greatest(%s, (select last_value from %s)))', 'public.' || sequencename, coalesce(last_value, 1) + 1000, 'public.' || sequencename), ';') from pg_sequences where schemaname = 'public'")" >/dev/null
fi

# Last check while nothing can change: from here on, the two sides are allowed to differ.
stamp "compare both databases while frozen"
docker exec -e PGPASSWORD="$(cat "$DRILL/admin.pw")" "$RDS" psql "host=10.77.0.20 dbname=shop user=mig_admin sslmode=require" -At -f /tmp/snapshot.sql >"$DRILL/source.json"
docker exec "$RDS" psql -U shopadmin -d shop -At -f /tmp/snapshot.sql >"$DRILL/target.json"
if ! "D:/devops-project/devops-project/.venv/Scripts/python.exe" -X utf8 "D:/devops-project/devops-project/tools/migration-data-check.py" \
    --source "D:/devops-project/.cache/migrate-drill/source.json" --target "D:/devops-project/.cache/migrate-drill/target.json" \
    --frozen --opened --out "D:/devops-project/.cache/migrate-drill/data-check.json"; then
  echo "STOP: the databases do not match. The source is still frozen and nothing has moved." >&2
  exit 1
fi

stamp "stop forward replication, start the way back"
dst "drop subscription shop_sub" 2>/dev/null
src "create subscription back_sub connection 'host=127.0.0.1 port=15432 dbname=shop user=repl_back password=$PW' publication back_pub with (copy_data = false, origin = none)" 2>/dev/null

stamp "open the target for writes"
dst "alter role shop_app reset default_transaction_read_only"
stamp "switch traffic"
bash "$HERE/edge.sh" aws 2>/dev/null
open=$(date +%s.%N)
stamp "cutover finished"
python -c "print(f'writes were stopped for {$open - $freeze:.1f} seconds')"
