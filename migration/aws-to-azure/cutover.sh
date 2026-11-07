#!/usr/bin/env bash
# Move the shop from AWS to Azure, keeping a way back. Same order as the on-prem drill: only the clouds differ.
#   bash cutover.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
PW=$(cat "$DRILL/repl.pw")

stamp "prove the app on Azure can use its storage: /ready only proves the database"
bash "$HERE/proof.sh" azure

stamp "before the freeze: copy and fully verify files, so the freeze only has to handle new ones"
sync_files s3-to-blob --verify
[ "$(az_sql "select count(*) from pg_publication where pubname = 'back_pub'")" = 1 ] || az_sql "create publication back_pub for all tables"

freeze=$(date +%s.%N)
stamp "FREEZE: the app on AWS can no longer write"
frozen_side=aws
aws_sql "alter role shop_app set default_transaction_read_only = on"
aws_sql "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'shop_app'" >/dev/null

stamp "wait for Azure to catch up"
want=$(aws_sql "select pg_current_wal_lsn()")
behind=""
for _ in $(seq 1 120); do
  behind=$(az_sql "select pg_wal_lsn_diff('$want', coalesce(latest_end_lsn, '0/0')) from pg_stat_subscription where pid is not null and relid is null limit 1")
  [ -n "$behind" ] && [ "${behind%.*}" -le 0 ] && break
  sleep 0.5
done
if [ -z "$behind" ] || [ "${behind%.*}" -gt 0 ]; then
  echo "STOP: Azure did not catch up (behind by ${behind:-unknown} bytes). No write was lost." >&2
  exit 1
fi
stamp "Azure caught up"

stamp "copy files made since the first pass"
sync_files s3-to-blob --verify-new --frozen --out /out/files-check.json

stamp "copy sequences: logical replication does not"
# Forward only: setval will happily wind a sequence back onto ids already used.
az_sql "$(aws_sql "select string_agg(format('select setval(%L, greatest(%s, (select last_value from %s)))', 'public.' || sequencename, coalesce(last_value, 1) + 1000, 'public.' || sequencename), ';') from pg_sequences where schemaname = 'public'")" >/dev/null

# Last check while nothing can change: from here on, the two sides are allowed to differ.
stamp "compare both databases while frozen"
if ! data_check --source "$DRILL_WIN/aws.json" --target "$DRILL_WIN/azure.json" --frozen --opened; then
  echo "STOP: the databases do not match. Nothing has moved." >&2
  exit 1
fi

stamp "stop forward replication, start the way back"
az_sql "drop subscription shop_sub" 2>/dev/null
aws_sql "create subscription back_sub connection 'host=$AZPG port=5432 dbname=shop user=mig_back password=$PW' publication back_pub with (copy_data = false, origin = none)" 2>/dev/null

stamp "open Azure for writes"
frozen_side=""
az_sql "alter role shop_app reset default_transaction_read_only"
stamp "switch traffic"
bash "$HERE/edge.sh" azure 2>/dev/null
open=$(date +%s.%N)
stamp "cutover finished"
python -c "print(f'writes were stopped for {$open - $freeze:.1f} seconds')"
