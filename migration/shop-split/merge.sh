#!/usr/bin/env bash
# Put the services back into the monolith, with customers shopping: split.sh in reverse, one seam at a time.
#   bash merge.sh catalog   stock goes back inside the order's transaction; catalog and its sweeper retire
#   bash merge.sh files     uploads come home from the files database; the files service retires
# Each step keeps a way back: the retired deployments stay at 0 replicas, and the files database keeps replicating.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

pending() { sql shop "select count(*) from reservations where status = 'pending'"; }

catalog_in() {
  [ "$(k get svc catalog -o jsonpath='{.spec.selector.deploy}')" = catalog ] \
    || { echo "STOP: catalog is not on the shared database. Run split.sh catalog-back first" >&2; exit 1; }
  stamp "give the monolith back the rights the split took: it updates stock itself again"
  sql shop "grant select, insert, update, delete on products to shop_app"

  stamp "the monolith takes stock in its own transaction again. Old and new pods can overlap: both write one database"
  k set env deploy/shop ORDER_MODE=local CATALOG_URL- >/dev/null
  k rollout status deploy/shop --timeout=240s | tail -1

  stamp "let the sweeper settle what the last saga orders left pending, then nothing calls catalog"
  for _ in $(seq 1 30); do [ "$(pending)" = 0 ] && break; sleep 5; done
  [ "$(pending)" = 0 ] || { echo "STOP: $(pending) reservations still pending: catalog stays up until they settle" >&2; exit 1; }
  k scale deploy/catalog-sweeper deploy/catalog deploy/catalog-next --replicas=0 >/dev/null
  stamp "catalog is part of the monolith again"
}

files_in() {
  [ "$(sql shop "select count(*) from pg_subscription where subname = 'files_back_sub' and subenabled")" = 1 ] \
    || { echo "STOP: the monolith is not receiving the files service's writes, so it is missing uploads" >&2; exit 1; }
  NODE=$(docker inspect "$EKS" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')

  stamp "prove the monolith can serve what the files service stored, before any traffic moves"
  rows=$(sql shop "select id || ' ' || sha256 from uploads order by created_at desc limit 5")
  while read -r id want; do
    got=$(docker exec shop-edge sh -c "wget -qO- http://$NODE:30080/uploads/$id | sha256sum" | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "STOP: the monolith cannot serve upload $id ($got)" >&2; exit 1; }
  done <<< "$rows"
  echo "proved: the monolith served the 5 newest uploads with the right bytes"
  sql shop "grant insert on uploads to shop_app"   # the split revoked it; nothing routes uploads here yet

  stamp "FREEZE file writes on the files database: orders carry on"
  undo=files_thaw
  sql postgres "alter role files_app in database files set default_transaction_read_only = on"
  sql files "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'files' and usename = 'files_app'" >/dev/null
  caught_up files shop files_back_sub
  stamp "compare the table that comes home"
  data_check files shop uploads --frozen --opened
  stamp "stop replicating home, start the way back, send file traffic to the monolith"
  sql shop "drop subscription files_back_sub" 2>/dev/null
  subscribe shop files files_home_back_sub files_pub "copy_data = false, origin = none"
  bash "$HERE/edge.sh" monolith >/dev/null
  undo=""
  k set env deploy/shop FILES_URL- >/dev/null
  k rollout status deploy/shop --timeout=240s | tail -1
  k scale deploy/files --replicas=0 >/dev/null
  stamp "files is part of the monolith again. The files database stays read-only, replicating, as the way back"
}
files_thaw() { sql postgres "alter role files_app in database files reset default_transaction_read_only"; }

case "${1:-}" in
  catalog) catalog_in ;;
  files) files_in ;;
  *) echo "usage: merge.sh catalog | files" >&2; exit 2 ;;
esac
