#!/usr/bin/env bash
# Back to "AWS is live, Azure is an empty copy that is replicating". Lab only: it wipes the target's rows.
#   bash reset-drill.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
PW=$(cat "$DRILL/repl.pw")

bash "$HERE/edge.sh" aws 2>/dev/null
az_sql "alter role shop_app set default_transaction_read_only = on"
aws_sql "alter role shop_app reset default_transaction_read_only"
aws_sql "drop subscription if exists back_sub" 2>/dev/null
az_sql "drop publication if exists back_pub"
az_sql "drop subscription if exists shop_sub" 2>/dev/null
for slot in $(aws_sql "select slot_name from pg_replication_slots where not active"); do aws_sql "select pg_drop_replication_slot('$slot')" >/dev/null; done
for slot in $(az_sql "select slot_name from pg_replication_slots where not active"); do az_sql "select pg_drop_replication_slot('$slot')" >/dev/null; done
az_sql "truncate order_items, orders, uploads, audit_log, products, customers cascade"
az_sql "create subscription shop_sub connection 'host=aws-rds port=5432 dbname=shop user=mig_repl password=$PW' publication shop_pub" 2>/dev/null
for _ in $(seq 1 120); do
  [ "$(az_sql "select count(*) from pg_subscription_rel where srsubstate <> 'r'")" = 0 ] && break
  sleep 2
done
az_sql "select count(*) || ' tables replicating' from pg_subscription_rel where srsubstate = 'r'"
