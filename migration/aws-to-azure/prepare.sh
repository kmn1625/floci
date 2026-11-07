#!/usr/bin/env bash
# Link the two clouds and start replicating. Safe to run again: each step checks before it acts.
#   bash prepare.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
PW=$(cat "$DRILL/repl.pw")
APP=$(cat "$DRILL/app.pw")

stamp "link the clouds: this stands in for the VPN or peering between them"
docker network inspect azure_default --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "$RDS" \
  || docker network connect --alias aws-rds azure_default "$RDS"
docker network inspect azure_default --format '{{range .Containers}}{{.Name}} {{end}}' | grep -qw floci-lab \
  || docker network connect azure_default floci-lab

stamp "source: a role that may replicate, and may read what it copies"
aws_sql "do \$\$ begin
  if not exists (select from pg_roles where rolname = 'mig_repl') then create role mig_repl login replication password '$PW'; end if;
end \$\$"
aws_sql "grant usage on schema public to mig_repl"
aws_sql "grant select on all tables in schema public to mig_repl"
aws_sql "select count(*) from pg_publication where pubname = 'shop_pub'" | grep -q 1 || aws_sql "create publication shop_pub for all tables"

stamp "target: wal_level, because Terraform said it was set and the server disagreed"
if [ "$(docker exec "$AZPG" psql -U shopadmin -d postgres -Atc 'show wal_level')" != logical ]; then
  docker exec "$AZPG" psql -U shopadmin -d postgres -qc "alter system set wal_level = logical"
  docker restart "$AZPG" >/dev/null
  for _ in $(seq 1 30); do docker exec "$AZPG" pg_isready -U shopadmin -q && break; sleep 1; done
fi
docker exec "$AZPG" psql -U shopadmin -d postgres -Atc 'show wal_level'

stamp "target: the database and its roles. Writes stay shut until cutover"
[ "$(docker exec "$AZPG" psql -U shopadmin -d postgres -Atc "select count(*) from pg_database where datname = 'shop'")" = 1 ] \
  || docker exec "$AZPG" psql -U shopadmin -d postgres -qc "create database shop"
az_sql "do \$\$ begin
  if not exists (select from pg_roles where rolname = 'shop_app') then create role shop_app login password '$APP'; end if;
  if not exists (select from pg_roles where rolname = 'mig_back') then create role mig_back login replication password '$PW'; end if;
end \$\$"
az_sql "alter role shop_app set default_transaction_read_only = on"

stamp "schema, moved as a file and checked afterwards"
if [ "$(az_sql "select count(*) from information_schema.tables where table_schema = 'public'")" = 0 ]; then
  docker exec -e PGPASSWORD="$PW" "$AZPG" pg_dump -h aws-rds -U mig_repl -d shop --schema-only --no-owner --no-privileges -f /tmp/schema.sql
  docker exec "$AZPG" grep -q 'database dump complete' /tmp/schema.sql || { echo "STOP: the schema dump is cut off" >&2; exit 1; }
  docker exec "$AZPG" psql -U shopadmin -d shop -v ON_ERROR_STOP=1 -q -f /tmp/schema.sql
fi
az_sql "grant usage on schema public to shop_app, mig_back"
az_sql "grant select, insert, update, delete on all tables in schema public to shop_app"
az_sql "grant usage, select on all sequences in schema public to shop_app"
az_sql "grant select on all tables in schema public to mig_back"

stamp "replicate"
[ "$(az_sql "select count(*) from pg_subscription")" = 0 ] \
  && az_sql "create subscription shop_sub connection 'host=aws-rds port=5432 dbname=shop user=mig_repl password=$PW' publication shop_pub"
for _ in $(seq 1 120); do
  left=$(az_sql "select count(*) from pg_subscription_rel where srsubstate <> 'r'")
  [ "$left" = 0 ] && [ "$(az_sql "select count(*) from pg_subscription_rel")" != 0 ] && break
  sleep 2
done
[ "${left:-1}" = 0 ] || { echo "STOP: $left tables have not reached ready" >&2; exit 1; }
az_sql "select count(*) || ' tables replicating' from pg_subscription_rel"
stamp "ready"
