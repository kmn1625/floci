#!/usr/bin/env bash
# Go back to AWS after a cutover, without losing what customers did on Azure in the meantime.
# Mirrors cutover.sh: freeze, catch up, files, sequences, compare, open, switch.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ "$(az_sql "select count(*) from pg_replication_slots where slot_name = 'back_sub' and active")" = 1 ] || {
  echo "STOP: nothing is replicating back to AWS, so there is no safe rollback from here." >&2
  exit 1
}

stamp "prove the app on AWS can still use its storage: it has been idle since cutover"
bash "$HERE/proof.sh" aws

freeze=$(date +%s.%N)
stamp "FREEZE: the app on Azure can no longer write"
frozen_side=az
az_sql "alter role shop_app set default_transaction_read_only = on"
az_sql "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'shop_app'" >/dev/null

stamp "wait for AWS to catch up"
want=$(az_sql "select pg_current_wal_lsn()")
behind=""
for _ in $(seq 1 120); do
  behind=$(az_sql "select pg_wal_lsn_diff('$want', confirmed_flush_lsn) from pg_replication_slots where slot_name = 'back_sub'")
  [ -n "$behind" ] && [ "${behind%.*}" -le 0 ] && break
  sleep 0.5
done
if [ -z "$behind" ] || [ "${behind%.*}" -gt 0 ]; then
  echo "STOP: AWS did not catch up (behind by ${behind:-unknown} bytes). Opening it now would lose those writes." >&2
  exit 1
fi
stamp "AWS caught up"

stamp "bring files made on Azure back to S3"
sync_files blob-to-s3 --verify-new --frozen

stamp "copy sequences back"
# Forward only: setval will happily wind a sequence back onto ids already used.
aws_sql "$(az_sql "select string_agg(format('select setval(%L, greatest(%s, (select last_value from %s)))', 'public.' || sequencename, coalesce(last_value, 1) + 1000, 'public.' || sequencename), ';') from pg_sequences where schemaname = 'public'")" >/dev/null

stamp "compare both databases while frozen"
if ! data_check --source "$DRILL_WIN/azure.json" --target "$DRILL_WIN/aws.json" --frozen --opened --rolling-back; then
  echo "STOP: the databases do not match. Azure still holds everything." >&2
  exit 1
fi

stamp "stop replication back"
aws_sql "drop subscription back_sub" 2>/dev/null

stamp "open AWS for writes"
frozen_side=""
aws_sql "alter role shop_app reset default_transaction_read_only"
stamp "switch traffic"
bash "$HERE/edge.sh" aws 2>/dev/null
open=$(date +%s.%N)
stamp "rollback finished"
python -c "print(f'writes were stopped for {$open - $freeze:.1f} seconds')"
