#!/usr/bin/env bash
# The traffic switch: nginx standing in for DNS or a global load balancer, attached to both clouds.
# Unlike DNS it moves instantly, so the drill does not measure TTLs or caching resolvers.
#   bash edge.sh start | aws | azure
set -euo pipefail
NAME=shop-edge
IMAGE=nginx:1.29.4-alpine
AKS=$(docker ps --filter name=floci-az-lab-aks- --format '{{.Names}}' | head -1)
AWS_NODE=$(docker inspect floci-aws-eks-shop --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
AZURE_NODE=$(docker inspect "$AKS" --format '{{.NetworkSettings.Networks.azure_default.IPAddress}}')

conf() {
  printf 'server {\n  listen 80;\n  client_max_body_size 3m;\n  location / {\n    proxy_pass http://%s;\n' "$1"
  printf '    proxy_connect_timeout 2s;\n    proxy_read_timeout 5s;\n    proxy_set_header Host $host;\n  }\n}\n'
}

case "$1" in
  start)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --memory 48m --cpus 0.3 -p 127.0.0.1:18080:80 "$IMAGE" >/dev/null
    docker network connect azure_default "$NAME"
    conf "$AWS_NODE:30080" | docker exec -i "$NAME" sh -c 'cat > /etc/nginx/aws.conf'
    conf "$AZURE_NODE:30080" | docker exec -i "$NAME" sh -c 'cat > /etc/nginx/azure.conf'
    docker exec "$NAME" sh -c 'cp /etc/nginx/aws.conf /etc/nginx/conf.d/default.conf && nginx -s reload' >/dev/null
    ;;
  aws | azure) docker exec "$NAME" sh -c "cp /etc/nginx/$1.conf /etc/nginx/conf.d/default.conf && nginx -s reload" >/dev/null ;;
  *) echo "usage: edge.sh start|aws|azure" >&2; exit 2 ;;
esac
echo "edge -> $1"
