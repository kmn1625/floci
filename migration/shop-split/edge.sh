#!/usr/bin/env bash
# The strangler: one address outside, and a route at a time moves behind it. nginx stands in for an API gateway.
#   bash edge.sh start                     everything to the monolith
#   bash edge.sh reads <percent> [fallback]  that share of file reads to the new service, writes stay put
#   bash edge.sh files                     all file traffic to the new service
#   bash edge.sh monolith                  all file traffic back
set -euo pipefail
NAME=shop-edge
IMAGE=nginx:1.29.4-alpine
NODE=$(docker inspect floci-aws-eks-shop --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')

conf() { # share of reads to files, where writes go, fallback (yes: a miss on the new side is retried on the old one)
  cat <<NGINX
upstream monolith { server $NODE:30080; }
upstream files { server $NODE:30081; }
split_clients "\$request_id" \$read_target {
$([ "$1" -gt 0 ] && echo "  $1% files;")
  * monolith;
}
server {
  listen 80;
  client_max_body_size 3m;
  proxy_connect_timeout 2s;
  proxy_read_timeout 5s;
  proxy_set_header Host \$host;
  location /internal/ { return 404; }
  location = /uploads { proxy_pass http://$2; }
  location /uploads/ {
    proxy_pass http://\$read_target;
$([ "$3" = yes ] && printf '    proxy_intercept_errors on;\n    error_page 404 = @old;\n')
  }
  location @old { proxy_pass http://monolith; }
  location / { proxy_pass http://monolith; }
}
NGINX
}

apply() { conf "$@" | docker exec -i "$NAME" sh -c 'cat > /etc/nginx/conf.d/default.conf && nginx -s reload 2>/dev/null'; }

case "$1" in
  start)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --memory 48m --cpus 0.3 -p 127.0.0.1:18080:80 "$IMAGE" >/dev/null
    sleep 1
    apply 0 monolith no
    ;;
  reads) apply "$2" monolith "${3:-no}" ;;
  files) apply 100 files no ;;
  monolith) apply 0 monolith no ;;
  *) echo "usage: edge.sh start | reads <percent> [yes] | files | monolith" >&2; exit 2 ;;
esac
echo "edge -> ${*}"
