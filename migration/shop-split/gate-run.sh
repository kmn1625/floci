#!/usr/bin/env bash
# The split gate on a real run: collect every file `migration-cutover-gate.py --split` reads, from the drill itself.
#   bash gate-run.sh <run-name>
# Catalog seam, with customers shopping: baseline, split check, attack drill, frozen per-item reconciliation, the move
# and its rollback under load, the restored check, then the gate. Evidence lands in .cache/migrate-drill/gate-<run-name>.
# monitoring.json comes from drills on the split shop (monitoring.sh must be up and forwarding). approval.json is never
# written here: a person other than the operator approves the printed digest on GitHub, and migration-approval.py records it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
RUN=${1:?usage: gate-run.sh <run-name>}
EV=$DRILL/gate-$RUN
EV_WIN=$DRILL_WIN/gate-$RUN
STOP=$EV/stop
export CATALOG_DB=catalog_$RUN
APP=$(cat "$DRILL/app.pw")
SHOP_APPS=D:/devops-project/floci/apps/shop
HERE_WIN=$(cd "$HERE" && pwd -W)   # python under MSYS_NO_PATHCONV needs Windows paths
[ ! -e "$EV" ] || { echo "STOP: $EV exists: pick a new run name, evidence is never overwritten" >&2; exit 1; }
mkdir -p "$EV/code" "$EV/counts"
trap 'touch "$STOP" 2>/dev/null; on_stop' EXIT

loads=$(powershell -NoProfile -c "@(Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { \$_.CommandLine -match 'load.py' }).Count" | tr -d '\r')
[ "$loads" = 0 ] || { echo "STOP: a load generator is already running" >&2; exit 1; }

snapshot() { # db file
  "$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" --print-sql > "$DRILL/snapshot.sql"
  docker cp "$DRILL_WIN/snapshot.sql" "$RDS:/tmp/snapshot.sql" >/dev/null
  docker exec "$RDS" psql -U shopadmin -d "$1" -At -f /tmp/snapshot.sql > "$2"
}
ev() { "$PYTHON" -X utf8 "$HERE_WIN/evidence.py" "$@"; }

PROM=http://127.0.0.1:19090
AM=http://127.0.0.1:19093
curl -sf -m 5 "$PROM/-/ready" >/dev/null && curl -sf -m 5 "$AM/-/ready" >/dev/null \
  || { echo "STOP: no monitoring on $PROM and $AM: bash monitoring.sh up, then keep bash monitoring.sh forward running" >&2; exit 1; }

stamp "0. catalog and its sweeper running: after a merge back they sit at zero"
k scale deploy/catalog --replicas=2 >/dev/null
k scale deploy/catalog-sweeper --replicas=1 >/dev/null
k rollout status deploy/catalog --timeout=240s | tail -1

stamp "1. the key a split drops goes back first, if no order item points at a missing product"
orphans=$(sql shop "select count(*) from order_items i left join products p on p.id = i.product_id where p.id is null")
[ "$orphans" = 0 ] || { echo "STOP: $orphans order items point at no product" >&2; exit 1; }
[ "$(sql shop "select count(*) from pg_constraint where conname = 'order_items_product_id_fkey'")" = 1 ] \
  || sql shop "alter table order_items add constraint order_items_product_id_fkey foreign key (product_id) references products (id)"

stamp "2. baseline: the monolith before this split"
snapshot shop "$EV/baseline.json"

stamp "3. what the split breaks, and who keeps each promise now"
cp "$SHOP_APPS"/app.py "$SHOP_APPS"/catalog.py "$SHOP_APPS"/files.py "$EV/code/"
echo '{"catalog": ["products", "reservations"], "files": ["uploads"], "orders": ["orders", "order_items", "customers", "audit_log"]}' > "$EV/boundary.json"
"$PYTHON" -X utf8 "$TOOLS/migration-split-check.py" --snapshot "$EV_WIN/baseline.json" --code "$EV_WIN/code" \
  --boundary "$EV_WIN/boundary.json" --out "$EV_WIN/split-check.raw.json" > "$EV/split-check.log" || true
[ -s "$EV/split-check.raw.json" ] || { cat "$EV/split-check.log"; echo "STOP: the split check wrote nothing" >&2; exit 1; }
ev resolve --raw "$EV_WIN/split-check.raw.json" --decisions "$HERE_WIN/split-decisions.json" --out "$EV_WIN/split-check.json" >/dev/null

stamp "4. attack: answers lost after commit, shop pods killed mid-request"
for d in catalog catalog-next; do  # count the lost answers: catalog's 502s come only from the injected fault
  [ -n "$(k get deploy $d -o jsonpath='{.spec.template.spec.containers[0].args}')" ] \
    || k patch deploy $d --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--access-logfile","-"]}]' >/dev/null
done
k scale deploy/catalog-next --replicas=0 >/dev/null
k rollout status deploy/catalog --timeout=240s | tail -1
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
skew=$("$PYTHON" -c "import time;print(round($(sql shop "select extract(epoch from now())") - time.time(), 2))")
bash "$HERE/experiment.sh" saga "${ATTACK_SECONDS:-90}" | tee "$EV/attack.log"
cp "$DRILL/exp-saga.jsonl" "$EV/attack.jsonl"
rc=0; "$PYTHON" -X utf8 "$LOAD_PY" check --url "$URL" --log "$EV_WIN/attack.jsonl" > "$EV/attack-check.json" || rc=$?
[ "$rc" -le 1 ] || { echo "STOP: the load check itself failed" >&2; exit 1; }
read -r first last < <(ev window --log "$EV_WIN/attack.jsonl" --skew "$skew")
committed=$(sql shop "select count(*) from orders where created_at between to_timestamp($first - 3) and to_timestamp($last + 15)")
lost=$(k logs -l deploy=catalog --since-time="$since" --tail=-1 2>/dev/null | grep -cE '" 502 ' || true)
killed=$(grep -c 'mid-request' "$EV/attack.log" || true)
budget=$(k get deploy shop -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RETRY_BUDGET")].value}')
timeout=$(docker exec shop-edge sh -c "grep -rhm1 'proxy_read_timeout' /etc/nginx/" | tr -dc '0-9.')
ev attack --log "$EV_WIN/attack.jsonl" --check "$EV_WIN/attack-check.json" --committed "$committed" --lost "$lost" \
  --killed "$killed" --budget "${budget:-3}" --timeout "$timeout" --out "$EV_WIN/attack-drill.json" >/dev/null

stamp "5. reconcile per product, with the writers of both owners frozen"
freeze_all() {
  sql postgres "alter role shop_app in database shop set default_transaction_read_only = on"
  sql postgres "alter role catalog_app in database shop set default_transaction_read_only = on"
  sql shop "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename in ('shop_app', 'catalog_app')" >/dev/null
}
unfreeze_all() {
  sql postgres "alter role shop_app in database shop reset default_transaction_read_only"
  sql postgres "alter role catalog_app in database shop reset default_transaction_read_only"
}
undo=unfreeze_all
freeze_all
sql shop "select coalesce(json_object_agg(id, initial_stock - stock), '{}') from products" > "$EV/counts/owner.json"
sql shop "select coalesce(json_object_agg(product_id, n), '{}') from (select product_id, sum(qty) n from order_items group by 1) s" > "$EV/counts/ledger.json"
sql shop "select coalesce(json_object_agg(pid, n), '{}') from (select l->>'product_id' pid, sum((l->>'qty')::int) n from reservations r, jsonb_array_elements(r.priced) l where r.status = 'pending' group by 1) s" > "$EV/counts/pending.json"
unfreeze_all
undo=""
"$PYTHON" -X utf8 "$TOOLS/migration-reconcile.py" --owner "$EV_WIN/counts/owner.json" --ledger "$EV_WIN/counts/ledger.json" \
  --pending "$EV_WIN/counts/pending.json" --frozen --out "$EV_WIN/reconcile.json" || true

stamp "6. move catalog to $CATALOG_DB under load, with 2% of its answers lost, then back"
k patch secret split-db -p "{\"stringData\":{\"catalog-own\":\"postgresql://catalog_app:$APP@$DB_HOST/$CATALOG_DB\"}}" >/dev/null
k set env deploy/catalog FAULT_LOST_ANSWER=0.02 >/dev/null
k set env deploy/catalog-next FAULT_LOST_ANSWER=0.02 >/dev/null
k rollout status deploy/catalog --timeout=240s | tail -1
"$PYTHON" -X utf8 "$LOAD_PY" run --url "$URL" --seconds 1200 --rate 5 --uploads 0.1 --out "$EV_WIN/move.jsonl" --stop-file "$EV_WIN/stop" > "$EV/move-load.log" 2>&1 &
LOAD=$!
sleep 20
bash "$HERE/split.sh" catalog | tee "$EV/move.log"
cp "$DRILL/split-data-check.json" "$EV/data-check.json"
cp "$DRILL/catalog-target-smoke.json" "$EV/target-smoke.json"
sleep "${OPEN_SECONDS:-30}"
bash "$HERE/split.sh" catalog-back | tee "$EV/back.log"
cp "$DRILL/split-data-check.json" "$EV/data-check-back.json"
sleep 15
touch "$STOP"
wait $LOAD
rc=0; "$PYTHON" -X utf8 "$LOAD_PY" check --url "$URL" --log "$EV_WIN/move.jsonl" > "$EV/move-check.json" || rc=$?
[ "$rc" -le 1 ] || { echo "STOP: the load check itself failed" >&2; exit 1; }
ev rollback --check "$EV_WIN/move-check.json" --out "$EV_WIN/rollback-drill.json" >/dev/null
k set env deploy/catalog FAULT_LOST_ANSWER=0 >/dev/null

stamp "7. after the rollback, against the baseline: is everything the monolith promised still there"
snapshot shop "$EV/after.json"
"$PYTHON" -X utf8 "$TOOLS/migration-data-check.py" --source "$EV_WIN/baseline.json" --target "$EV_WIN/after.json" \
  --schema-only --opened --out "$EV_WIN/restored-check.json" || true

# The catalog seam owns no files: an honest zero, not a skipped check.
echo '{"inDatabase": 0, "notInBucket": 0, "hashed": 0, "checksumMismatch": 0, "note": "the catalog seam moves no files"}' > "$EV/files-check.json"

stamp "8. monitoring on the split shop: each alert made to fire, reach the pager and clear, one fault at a time"
mon() { "$PYTHON" -X utf8 "$TOOLS/migration-monitoring-check.py" "$@"; }
drill() { # alert inject restore
  mon drill --prometheus "$PROM" --alertmanager "$AM" --alert "$1" --inject "$2" --restore "$3" --log "$EV_WIN/drills.jsonl" \
    --timeout 300 | tee -a "$EV/drills.log" || true
}
psql_c() { echo "docker exec $RDS psql -U shopadmin -d $1 -Atc \"$2\""; }
# Stock taken with no order behind it, as a lost write would leave it.
drill ShopStockDrift "$(psql_c shop "update products set stock = stock - 2 where id = 7")" \
  "$(psql_c shop "update products set stock = stock + 2 where id = 7")"
# Customers' writes failing: the shop's role made read-only, with shoppers on the site.
"$PYTHON" -X utf8 "$LOAD_PY" run --url "$URL" --seconds 600 --rate 5 --uploads 0.1 --out "$EV_WIN/drill-load.jsonl" \
  --stop-file "$EV_WIN/drill-stop" > "$EV/drill-load.log" 2>&1 &
DLOAD=$!
sleep 60   # a minute of normal traffic first: the error rate needs something to compare with
drill ShopErrorRate "$(psql_c postgres "alter role shop_app in database shop set default_transaction_read_only = on") && $(psql_c shop \
  "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'shop_app'")" \
  "$(psql_c postgres "alter role shop_app in database shop reset default_transaction_read_only")"
touch "$EV/drill-stop"
wait $DLOAD || true
# Nothing scraped at all: every other alert would stay silent.
drill ShopTargetMissing "docker exec $EKS kubectl -n shop scale deploy/shop --replicas=0" \
  "docker exec $EKS kubectl -n shop scale deploy/shop --replicas=2"
k rollout status deploy/shop --timeout=240s | tail -1
sleep 30
mon check --prometheus "$PROM" --alertmanager "$AM" --alert ShopErrorRate --alert ShopTargetMissing --reconcile-alert ShopStockDrift \
  --dashboard "$HERE_WIN/shop-dashboard.json" --minutes 60 --drills "$EV_WIN/drills.jsonl" --out "$EV_WIN/monitoring.json" || true

stamp "9. the gate, split mode"
rc=0; "$PYTHON" -X utf8 "$TOOLS/migration-cutover-gate.py" --evidence "$EV_WIN" --split --out "$EV_WIN/decision.json" || rc=$?
echo "gate exit $rc"
digest=$("$PYTHON" -X utf8 "$TOOLS/migration-cutover-gate.py" --evidence "$EV_WIN" --digest)
echo "$digest" > "$EV/evidence-digest.txt"
echo "To approve, someone other than the operator comments, on a line of its own:  approve cutover $digest"
echo "then: python tools/migration-approval.py --evidence $EV_WIN --operator <who ran this> --url <link to the comment>"
verify
