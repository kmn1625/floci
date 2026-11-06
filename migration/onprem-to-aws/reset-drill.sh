#!/usr/bin/env bash
# Put everything back to "on-prem is live, target is an empty copy that is replicating".
# Lab only: it wipes the target's data. Traffic goes to on-prem first, so nothing writes to the target.
set -euo pipefail
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "$0")" && pwd)
DRILL=/d/devops-project/.cache/migrate-drill
RDS=$(cat "$DRILL/rds.name")
PW=$(cat "$DRILL/migrator.pw")
src() { timeout 25 multipass exec onprem1 -- sudo -u postgres psql -d shop -v ON_ERROR_STOP=1 -q "$@"; }
dst() { docker exec -i "$RDS" psql -U shopadmin -d shop -v ON_ERROR_STOP=1 -q "$@"; }

bash "$HERE/edge.sh" onprem 2>/dev/null
dst -c "alter role shop_app set default_transaction_read_only = on"
src -c "drop subscription if exists back_sub" >/dev/null 2>&1 || true
dst -c "drop publication if exists back_pub"
dst -c "drop subscription if exists shop_sub" 2>/dev/null || true
src -c "alter role shop reset default_transaction_read_only"
dst -c "truncate order_items, orders, uploads, audit_log, products, customers cascade"
src -c "select setval('orders_id_seq', greatest((select max(id) from orders), (select last_value from orders_id_seq)))" \
    -c "select setval('order_items_id_seq', greatest((select max(id) from order_items), (select last_value from order_items_id_seq)))" >/dev/null
# The bucket stays: the sync only copies what is missing, and strays do no harm.
dst -c "create subscription shop_sub connection 'host=10.77.0.20 port=5432 dbname=shop user=migrator password=$PW sslmode=require' publication shop_pub" 2>/dev/null
for _ in $(seq 1 40); do
  [ "$(dst -Atc "select count(*) from pg_subscription_rel where srsubstate <> 'r'")" = 0 ] && break
  sleep 1.5
done
dst -Atc "select count(*) || ' tables replicating' from pg_subscription_rel where srsubstate = 'r'"
