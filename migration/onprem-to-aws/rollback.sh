#!/usr/bin/env bash
# Go back to on-prem after a cutover, without losing what customers did on AWS in the meantime.
# Mirrors cutover.sh: freeze, catch up, files, sequences, open, switch.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "$0")" && pwd)
DRILL=/d/devops-project/.cache/migrate-drill
RDS=$(cat "$DRILL/rds.name")

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

[ "$(dst "select count(*) from pg_replication_slots where slot_name = 'back_sub' and active")" = 1 ] || {
  echo "STOP: nothing is replicating back to on-prem, so there is no safe rollback from here." >&2
  exit 1
}

freeze=$(date +%s.%N)
stamp "FREEZE: the app on AWS can no longer write"
dst "alter role shop_app set default_transaction_read_only = on"
dst "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'shop_app'" >/dev/null

stamp "wait for on-prem to catch up"
want=$(dst "select pg_current_wal_lsn()")
for _ in $(seq 1 120); do
  behind=$(dst "select pg_wal_lsn_diff('$want', confirmed_flush_lsn) from pg_replication_slots where slot_name = 'back_sub'")
  [ -n "$behind" ] && [ "${behind%.*}" -le 0 ] && break
  sleep 0.5
done
if [ -z "${behind:-}" ] || [ "${behind%.*}" -gt 0 ]; then
  echo "STOP: on-prem did not catch up (behind by ${behind:-unknown} bytes). Opening it now would lose those writes." >&2
  exit 1
fi
stamp "on-prem caught up"

stamp "bring files made on AWS home"
timeout 60 multipass exec onprem1 -- sudo env AWS_ACCESS_KEY_ID=floci AWS_SECRET_ACCESS_KEY=floci S3_ENDPOINT=http://127.0.0.1:14566 \
  S3_BUCKET=shop-uploads /opt/shop/venv/bin/python /home/ubuntu/sync-back.py | tr -d '\r'

stamp "copy sequences back"
# Forward only: setval will happily wind a sequence back onto ids already used.
src "$(dst "select string_agg(format('select setval(%L, greatest(%s, (select last_value from %s)))', 'public.' || sequencename, coalesce(last_value, 1) + 1000, 'public.' || sequencename), ';') from pg_sequences where schemaname = 'public'")" >/dev/null

stamp "open on-prem for writes"
src "alter role shop reset default_transaction_read_only"
stamp "switch traffic"
bash "$HERE/edge.sh" onprem 2>/dev/null
open=$(date +%s.%N)
stamp "rollback finished"
python -c "print(f'writes were stopped for {$open - $freeze:.1f} seconds')"
