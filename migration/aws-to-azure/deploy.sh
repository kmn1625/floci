#!/usr/bin/env bash
# Put the same image on both clouds. It goes live on AWS first: a build that speaks both storage APIs has to
# be running at the source before any move, or a rollback lands on an app that cannot read the new world.
#   bash deploy.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

load() { # image into a k3s node, as a file: multipass and docker pipes through Git Bash are not to be trusted
  docker cp "$DRILL_WIN/shop-$TAG.tar" "$1:/tmp/shop.tar"
  docker exec "$1" ctr -n k8s.io images import /tmp/shop.tar >/dev/null
  docker exec "$1" rm -f /tmp/shop.tar
}

[ -f "$DRILL/shop-$TAG.tar" ] || docker save -o "$DRILL_WIN/shop-$TAG.tar" "shop:$TAG"

stamp "AWS first: same behaviour, new image"
load "$EKS"
docker exec "$EKS" kubectl -n shop set image deploy/shop "shop=shop:$TAG"
docker exec "$EKS" kubectl -n shop rollout status deploy/shop --timeout=180s | tail -1

stamp "Azure: read-only until cutover"
load "$AKS"
AZPG_IP=$(docker inspect "$AZPG" --format '{{.NetworkSettings.Networks.azure_default.IPAddress}}')
FLOCI_AZ_IP=$(docker inspect floci-az --format '{{.NetworkSettings.Networks.azure_default.IPAddress}}')
sed -e "s#__DATABASE_URL__#postgresql://shop_app:$(cat "$DRILL/app.pw")@$AZPG_IP:5432/shop#" \
    -e "s#__BLOB_KEY__#$(cat "$DRILL/az-storage.key")#" \
    -e "s#__BLOB_URL__#http://$FLOCI_AZ_IP:4577/$ACCOUNT#" \
    -e "s#__ACCOUNT__#$ACCOUNT#" "$HERE/shop.aks.yaml" > "$DRILL/shop.aks.rendered.yaml"
docker cp "$DRILL_WIN/shop.aks.rendered.yaml" "$AKS:/tmp/shop.yaml"
docker exec "$AKS" kubectl apply -f /tmp/shop.yaml
docker exec "$AKS" rm -f /tmp/shop.yaml
rm -f "$DRILL/shop.aks.rendered.yaml"
docker exec "$AKS" kubectl -n shop rollout status deploy/shop --timeout=240s | tail -1
stamp "both clouds run $TAG"
