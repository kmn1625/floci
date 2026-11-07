#!/usr/bin/env bash
# Everything the split needs that changes no behaviour: the new columns and roles, the image, the idle services.
# The monolith still does everything when this finishes. Safe to run again.
#   bash setup.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"
APP=$(cat "$DRILL/app.pw")
FLOCI_IP=$(docker inspect floci-lab --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' | tr ' ' '\n' | grep '^172\.17\.' | head -1 || true)
[ -n "$FLOCI_IP" ] || FLOCI_IP=$(k get deploy shop -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="S3_ENDPOINT")].value}' | sed -E 's#http://([^:]+):.*#\1#')

stamp "expand first: additive changes the running monolith does not notice"
sql shop "alter table orders add column if not exists order_key uuid unique"
sql shop "create table if not exists reservations (key uuid primary key, status text not null, priced jsonb, created_at timestamptz not null default now())"
sql shop "create index if not exists reservations_pending on reservations (created_at) where status = 'pending'"
sql shop "grant select on all tables in schema public to mig_repl"

stamp "a role per service: what a service cannot touch, it cannot secretly depend on"
for role in catalog_app files_app; do
  sql shop "do \$\$ begin if not exists (select from pg_roles where rolname = '$role') then create role $role login password '$APP'; end if; end \$\$"
done
sql shop "grant usage on schema public to catalog_app, files_app"
sql shop "grant select, update on products to catalog_app"
sql shop "grant select, insert, update on reservations to catalog_app"
sql shop "grant select on uploads to files_app"

stamp "the new image, on the monolith first"
[ -f "$DRILL/shop-$TAG.tar" ] || docker save -o "$DRILL_WIN/shop-$TAG.tar" "shop:$TAG"
docker cp "$DRILL_WIN/shop-$TAG.tar" "$EKS:/tmp/shop.tar"
docker exec "$EKS" ctr -n k8s.io images import /tmp/shop.tar >/dev/null
docker exec "$EKS" rm -f /tmp/shop.tar
k set image deploy/shop "shop=shop:$TAG" >/dev/null
k rollout status deploy/shop --timeout=240s | tail -1

stamp "the services, idle"
K=$(mktemp)
{
  echo "stringData:"
  echo "  catalog-shared: postgresql://catalog_app:$APP@$DB_HOST/shop"
  echo "  catalog-own: postgresql://catalog_app:$APP@$DB_HOST/catalog"
  echo "  files-own: postgresql://files_app:$APP@$DB_HOST/files"
} > "$K"
{ printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: split-db\n  namespace: shop\ntype: Opaque\n'; cat "$K"; } > "$DRILL/split.rendered.yaml"
rm -f "$K"
render() { # name service secret-key replicas
  printf -- '---\n'
  sed -e "s/__NAME__/$1/g" -e "s/__SERVICE__/$2/g" -e "s/__SECRET_KEY__/$3/g" -e "s/__REPLICAS__/$4/g" -e "s/__TAG__/$TAG/g" -e "s/__FLOCI_IP__/$FLOCI_IP/g" "$HERE/service.tmpl.yaml"
}
{ render catalog catalog catalog-shared 2; render catalog-next catalog catalog-own 0; render files files files-own 0
  printf -- '---\n'; sed -e "s/__TAG__/$TAG/g" "$HERE/split.k8s.yaml"; } >> "$DRILL/split.rendered.yaml"
docker cp "$DRILL_WIN/split.rendered.yaml" "$EKS:/tmp/split.yaml"
docker exec "$EKS" kubectl apply -f /tmp/split.yaml | cut -c1-60
docker exec "$EKS" rm -f /tmp/split.yaml
rm -f "$DRILL/split.rendered.yaml"
k rollout status deploy/catalog --timeout=240s | tail -1
stamp "ready: the monolith still does everything"
verify
