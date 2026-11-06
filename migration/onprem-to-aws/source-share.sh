#!/usr/bin/env bash
# Serve the uploads folder to the sync client only, for the length of the migration. Run as root.
#   bash source-share.sh on | off
set -euo pipefail
SITE=/etc/nginx/sites-enabled/shop-migration
case "$1" in
  on)
    cat >"$SITE" <<'NGINX'
server {
  listen 10.77.0.20:8099;
  allow 10.77.0.1;
  deny all;
  root /var/lib/shop/uploads;
  location / {
    autoindex on;
    autoindex_format json;
  }
}
NGINX
    ;;
  off) rm -f "$SITE" ;;
  *) echo "usage: source-share.sh on|off" >&2; exit 2 ;;
esac
nginx -t -q
systemctl reload nginx
echo "share $1"
