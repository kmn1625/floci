#!/usr/bin/env bash
# Carve the monolith one seam at a time, with traffic running. Each step can stop and leave the shop working.
#   bash split.sh files          the easy seam: uploads, no key and no shared transaction
#   bash split.sh catalog        the hard seam: stock, already behind an API, now moves its data
#   bash split.sh catalog-back   undo that move, keeping what was written since
# CATALOG_DB names catalog's own database (default catalog). A re-run needs a new one: the old one still holds the last run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
CATALOG_DB=${CATALOG_DB:-catalog}
APP=$(cat "$DRILL/app.pw")
PW=$(cat "$DRILL/repl.pw")

new_db() { # db tables... : a database with only this service's tables, moved as a file and checked
  local db=$1
  shift
  [ "$(docker exec "$RDS" psql -U shopadmin -d postgres -Atc "select count(*) from pg_database where datname = '$db'")" = 1 ] \
    || docker exec "$RDS" psql -U shopadmin -d postgres -qc "create database $db"
  [ "$(sql "$db" "select count(*) from information_schema.tables where table_schema = 'public'")" = 0 ] || return 0
  local flags=""
  for t in "$@"; do flags="$flags -t public.$t"; done
  docker exec "$RDS" sh -c "pg_dump -U shopadmin -d shop --schema-only --no-owner --no-privileges $flags -f /tmp/$db.sql"
  docker exec "$RDS" grep -q 'database dump complete' "/tmp/$db.sql" || { echo "STOP: the schema dump is cut off" >&2; exit 1; }
  docker exec "$RDS" psql -U shopadmin -d "$db" -v ON_ERROR_STOP=1 -q -f "/tmp/$db.sql"
}

files_move() {
  stamp "a database of its own, replicating. The service starts read-only"
  new_db files uploads
  sql files "grant usage on schema public to files_app, mig_repl"
  sql files "grant select, insert on uploads to files_app"
  sql files "grant select on uploads to mig_repl"
  sql postgres "alter role files_app in database files set default_transaction_read_only = on"
  [ "$(sql shop "select count(*) from pg_publication where pubname = 'files_pub'")" = 1 ] || sql shop "create publication files_pub for table uploads"
  [ "$(sql files "select count(*) from pg_subscription where subname = 'files_sub'")" = 1 ] || subscribe shop files files_sub files_pub
  for _ in $(seq 1 60); do [ "$(sql files "select count(*) from pg_subscription_rel where srsubstate <> 'r'")" = 0 ] && break; sleep 1; done
  k scale deploy/files --replicas=2 >/dev/null
  k rollout status deploy/files --timeout=240s | tail -1

  stamp "prove the new service reaches its storage, through its own code"
  docker exec "$EKS" kubectl -n shop exec deploy/files -- python -c '
import files, uuid
key = f"proof-{uuid.uuid4()}"
files.s3.put_object(Bucket=files.BUCKET, Key=key, Body=b"proof")
assert files.s3.get_object(Bucket=files.BUCKET, Key=key)["Body"].read() == b"proof"
print("proved")'

  stamp "canary: 10% of reads to the new service, writes stay on the monolith"
  bash "$HERE/edge.sh" reads 10 >/dev/null
  sleep "${CANARY_SECONDS:-45}"
  stamp "all reads, with a miss falling back to the monolith: a replica can be behind a customer's own upload"
  bash "$HERE/edge.sh" reads 100 yes >/dev/null
  sleep "${CANARY_SECONDS:-45}"

  stamp "FREEZE file writes only: orders carry on"
  undo=files_unfreeze
  sql shop "revoke insert on uploads from shop_app"
  sql shop "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'shop_app' and pid <> pg_backend_pid() and query ilike '%uploads%'" >/dev/null
  caught_up shop files files_sub
  stamp "compare the table that moved"
  data_check shop files uploads --frozen --opened
  stamp "stop replicating, start the way back, open the service"
  sql files "drop subscription files_sub" 2>/dev/null
  sql files "create publication files_back_pub for table uploads"
  subscribe files shop files_back_sub files_back_pub "copy_data = false, origin = none"
  undo=""
  sql postgres "alter role files_app in database files reset default_transaction_read_only"
  k rollout restart deploy/files >/dev/null
  k rollout status deploy/files --timeout=240s | tail -1
  bash "$HERE/edge.sh" files >/dev/null
  k set env deploy/shop FILES_URL=http://files >/dev/null
  stamp "files is its own service"
}
files_unfreeze() { sql shop "grant insert on uploads to shop_app"; }

catalog_move() {
  stamp "the key to products goes first: orders stop assuming the table is next door"
  sql shop "alter table order_items drop constraint if exists order_items_product_id_fkey"
  sql shop "revoke update, insert, delete on products from shop_app"
  stamp "a database of its own, replicating. The new deployment starts read-only"
  new_db "$CATALOG_DB" products reservations
  sql "$CATALOG_DB" "grant usage on schema public to catalog_app, mig_repl"
  sql "$CATALOG_DB" "grant select, update on products to catalog_app"
  sql "$CATALOG_DB" "grant select, insert, update on reservations to catalog_app"
  sql "$CATALOG_DB" "grant select on products, reservations to mig_repl"
  sql postgres "alter role catalog_app in database $CATALOG_DB set default_transaction_read_only = on"
  [ "$(sql shop "select count(*) from pg_publication where pubname = 'catalog_pub'")" = 1 ] || sql shop "create publication catalog_pub for table products, reservations"
  [ "$(sql "$CATALOG_DB" "select count(*) from pg_subscription where subname = 'catalog_sub'")" = 1 ] || subscribe shop "$CATALOG_DB" catalog_sub catalog_pub
  for _ in $(seq 1 60); do [ "$(sql "$CATALOG_DB" "select count(*) from pg_subscription_rel where srsubstate <> 'r'")" = 0 ] && break; sleep 1; done
  k scale deploy/catalog-next --replicas=2 >/dev/null
  k rollout status deploy/catalog-next --timeout=240s | tail -1

  stamp "prove the new deployment reaches its database through its own code, and may write what it must once opened"
  # Writing now would put rows on the target before cutover (M007): prove the connection and the grants instead.
  docker exec -i "$EKS" kubectl -n shop exec -i deploy/catalog-next -- python - > "$DRILL/catalog-proof.json" <<'PY'
import catalog, json
with catalog.db() as conn:
    one = lambda q: conn.execute(q).fetchone()[0]
    proved = {"catalog-next reads products": one("select count(*) from products") > 0,
              "catalog_app may update products": one("select has_table_privilege(current_user, 'products', 'UPDATE')"),
              "catalog_app may insert reservations": one("select has_table_privilege(current_user, 'reservations', 'INSERT')"),
              "catalog_app may update reservations": one("select has_table_privilege(current_user, 'reservations', 'UPDATE')"),
              "connected to its own database": one("select current_database()") != "shop"}
print(json.dumps(proved))
PY
  "$PYTHON" -c "import json,sys,datetime; p=json.load(open(sys.argv[1])); json.dump({'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'proved': p}, open(sys.argv[2], 'w'), indent=2); print(p); sys.exit(0 if all(p.values()) else 1)" \
    "$DRILL_WIN/catalog-proof.json" "$DRILL_WIN/catalog-target-smoke.json" || { echo "STOP: catalog-next cannot do its job on its own database" >&2; exit 1; }

  stamp "FREEZE stock: orders are refused, nothing else is"
  undo=catalog_unfreeze
  sql postgres "alter role catalog_app in database shop set default_transaction_read_only = on"
  sql shop "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'shop' and usename = 'catalog_app'" >/dev/null
  caught_up shop "$CATALOG_DB" catalog_sub
  stamp "copy the sequence, forward only"
  sql "$CATALOG_DB" "$(sql shop "select string_agg(format('select setval(%L, greatest(%s, (select last_value from %s)))', 'public.' || sequencename, coalesce(last_value, 1) + 1000, 'public.' || sequencename), ';') from pg_sequences where schemaname = 'public' and sequencename = 'products_id_seq'")" >/dev/null
  stamp "compare the tables that moved"
  data_check shop "$CATALOG_DB" products,reservations --frozen --opened
  stamp "stop replicating, start the way back, open and point the service at the new database"
  sql "$CATALOG_DB" "drop subscription catalog_sub" 2>/dev/null
  sql "$CATALOG_DB" "create publication catalog_back_pub for table products, reservations"
  subscribe "$CATALOG_DB" shop catalog_back_sub catalog_back_pub "copy_data = false, origin = none"
  undo=""
  sql postgres "alter role catalog_app in database $CATALOG_DB reset default_transaction_read_only"
  docker exec "$RDS" psql -U shopadmin -d "$CATALOG_DB" -qc "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$CATALOG_DB' and usename = 'catalog_app'" >/dev/null
  k patch service catalog -p '{"spec":{"selector":{"deploy":"catalog-next"}}}' >/dev/null
  stamp "catalog is its own service"
}
catalog_unfreeze() { sql postgres "alter role catalog_app in database shop reset default_transaction_read_only"; }

catalog_back() {
  [ "$(sql "$CATALOG_DB" "select count(*) from pg_replication_slots where slot_name = 'catalog_back_sub' and active")" = 1 ] || {
    echo "STOP: nothing is replicating back, so there is no safe rollback from here." >&2
    exit 1
  }
  stamp "FREEZE stock on the new database"
  undo=catalog_refreeze_back
  sql postgres "alter role catalog_app in database $CATALOG_DB set default_transaction_read_only = on"
  sql "$CATALOG_DB" "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = '$CATALOG_DB' and usename = 'catalog_app'" >/dev/null
  caught_up "$CATALOG_DB" shop catalog_back_sub
  stamp "compare, going back"
  data_check "$CATALOG_DB" shop products,reservations --frozen --opened
  stamp "stop replicating, open the old database, point the service back"
  sql shop "drop subscription catalog_back_sub" 2>/dev/null
  undo=""
  sql postgres "alter role catalog_app in database shop reset default_transaction_read_only"
  k patch service catalog -p '{"spec":{"selector":{"deploy":"catalog"}}}' >/dev/null
  k rollout restart deploy/catalog >/dev/null
  k rollout status deploy/catalog --timeout=240s | tail -1
  stamp "put back the key the move dropped: both tables share a database again, so it can be enforced again"
  # The gate's restored check found it missing after the 7 Nov rollback. NOT VALID first: no long lock under traffic.
  [ "$(sql shop "select count(*) from pg_constraint where conname = 'order_items_product_id_fkey'")" = 1 ]     || sql shop "alter table order_items add constraint order_items_product_id_fkey foreign key (product_id) references products (id) not valid"
  sql shop "alter table order_items validate constraint order_items_product_id_fkey"
  stamp "give back the rights the move took: the monolith updates stock itself if catalog is ever merged back"
  # The 7 Nov rollback left shop_app with only SELECT on products; the 8 Nov merge found it before any order failed.
  sql shop "grant select, insert, update, delete on products to shop_app"
  stamp "catalog is back on the shared database"
}
catalog_refreeze_back() { sql postgres "alter role catalog_app in database $CATALOG_DB reset default_transaction_read_only"; }

case "${1:-}" in
  files) files_move ;;
  catalog) catalog_move ;;
  catalog-back) catalog_back ;;
  *) echo "usage: split.sh files | catalog | catalog-back" >&2; exit 2 ;;
esac
