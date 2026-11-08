#!/usr/bin/env bash
# Services back into the monolith, under load, with evidence: bash merge-run.sh <run-name>
# Writes .cache/migrate-drill/merge-<run-name>: the load log and its check, the data check, a frozen reconciliation,
# and the merged schema against the monolith's baseline from before the split (gate-r3/baseline.json).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
RUN=${1:?usage: merge-run.sh <run-name>}
EV=$DRILL/merge-$RUN
EV_WIN=$DRILL_WIN/merge-$RUN
BASELINE=$DRILL_WIN/gate-r3/baseline.json
[ ! -e "$EV" ] || { echo "STOP: $EV exists: evidence is never overwritten" >&2; exit 1; }
[ -f "$BASELINE" ] || { echo "STOP: no baseline at $BASELINE" >&2; exit 1; }
mkdir -p "$EV/counts"
trap 'touch "$EV/stop" 2>/dev/null; on_stop' EXIT

loads=$(powershell -NoProfile -c "@(Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { \$_.CommandLine -match 'load.py' }).Count" | tr -d '\r')
[ "$loads" = 0 ] || { echo "STOP: a load generator is already running" >&2; exit 1; }

stamp "before"
verify | tee "$EV/verify-before.json"
"$PYTHON" -X utf8 "$LOAD_PY" run --url "$URL" --seconds 1200 --rate 5 --uploads 0.15 --read-back --out "$EV_WIN/load.jsonl" \
  --stop-file "$EV_WIN/stop" > "$EV/load.log" 2>&1 &
LOAD=$!
sleep 30

bash "$HERE/merge.sh" catalog | tee "$EV/catalog.log"
sleep "${GAP_SECONDS:-30}"
bash "$HERE/merge.sh" files | tee "$EV/files.log"
cp "$DRILL/split-data-check.json" "$EV/data-check.json"
sleep "${GAP_SECONDS:-30}"
touch "$EV/stop"
wait $LOAD

stamp "every write a customer was told succeeded, read back through the monolith"
rc=0; "$PYTHON" -X utf8 "$LOAD_PY" check --url "$URL" --log "$EV_WIN/load.jsonl" > "$EV/load-check.json" || rc=$?
cat "$EV/load-check.json"
[ "$rc" -le 1 ] || { echo "STOP: the load check itself failed" >&2; exit 1; }

stamp "reconcile per product with the monolith's writes frozen: one database keeps the promise again"
undo=thaw
sql postgres "alter role shop_app in database shop set default_transaction_read_only = on"
sql shop "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'shop_app'" >/dev/null
sql shop "select coalesce(json_object_agg(id, initial_stock - stock), '{}') from products" > "$EV/counts/owner.json"
sql shop "select coalesce(json_object_agg(product_id, n), '{}') from (select product_id, sum(qty) n from order_items group by 1) s" > "$EV/counts/ledger.json"
thaw() { sql postgres "alter role shop_app in database shop reset default_transaction_read_only"; }
thaw
undo=""
"$PYTHON" -X utf8 "$TOOLS/migration-reconcile.py" --owner "$EV_WIN/counts/owner.json" --ledger "$EV_WIN/counts/ledger.json" \
  --frozen --out "$EV_WIN/reconcile.json" || true

stamp "the merged monolith against its own baseline from before the split: is every promise back"
"$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" --print-sql > "$DRILL/snapshot.sql"
docker cp "$DRILL_WIN/snapshot.sql" "$RDS:/tmp/snapshot.sql" >/dev/null
docker exec "$RDS" psql -U shopadmin -d shop -At -f /tmp/snapshot.sql > "$EV/after.json"
"$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" --source "$BASELINE" --target "$EV_WIN/after.json" --schema-only --opened \
  --out "$EV_WIN/restored-check.json" || true

stamp "after"
verify | tee "$EV/verify-after.json"
k get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas --no-headers
