#!/usr/bin/env bash
# The traffic switch: an nginx in front of the app, standing in for DNS or a load balancer.
# Unlike DNS it moves instantly, so the drill does not measure TTLs or caching resolvers.
#   bash edge.sh start | onprem | aws
set -euo pipefail
NAME=shop-edge
IMAGE=nginx:1.29.4-alpine
AWS_NODE=$(docker inspect floci-aws-eks-shop --format '{{.NetworkSettings.Networks.bridge.IPAddress}}' 2>/dev/null || true)

conf() {
  cat <<NGINX
server {
  listen 80;
  client_max_body_size 3m;
  location / {
    proxy_pass http://$1;
    proxy_connect_timeout 2s;
    proxy_read_timeout 5s;
    proxy_set_header Host \$host;
  }
}
NGINX
}

case "$1" in
  start)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --memory 48m --cpus 0.3 -p 127.0.0.1:18080:80 "$IMAGE" >/dev/null
    conf 10.77.0.20:80 | docker exec -i "$NAME" sh -c 'cat > /etc/nginx/onprem.conf'
    conf "$AWS_NODE:30080" | docker exec -i "$NAME" sh -c 'cat > /etc/nginx/aws.conf'
    docker exec "$NAME" sh -c 'cp /etc/nginx/onprem.conf /etc/nginx/conf.d/default.conf && nginx -s reload' >/dev/null
    ;;
  onprem | aws) docker exec "$NAME" sh -c "cp /etc/nginx/$1.conf /etc/nginx/conf.d/default.conf && nginx -s reload" >/dev/null ;;
  *) echo "usage: edge.sh start|onprem|aws" >&2; exit 2 ;;
esac
echo "edge -> $1"
