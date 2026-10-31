#!/usr/bin/env bash
# After a laptop/Docker restart: floci-az comes back (restart: unless-stopped) but the
# containers it launched (ACR registry, AKS k3s, Postgres, MySQL, Redis) stay Exited,
# and the k3s node dies with "failed to find interface with specified node ip"
# because Docker hands it a new address (FINDINGS.md F-31).
#
#   bash azure/scripts/recover-after-restart.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")/.." && pwd)"
net=azure_default

aks=$(docker ps -a --filter "name=floci-az-lab-aks-" --format '{{.Names}}' | head -1)
want_ip=$(cat "$here/out/aks.ip" 2>/dev/null || true)

# 1. AKS first, so it can reclaim its old address before anything else takes it.
if [ -n "$aks" ] && [ -n "$want_ip" ]; then
  holder=$(docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}' \
           | awk -v ip="$want_ip/" 'index($2, ip) == 1 {print $1}')
  if [ -n "$holder" ] && [ "$holder" != "$aks" ]; then
    echo "moving $holder off $want_ip"
    docker network disconnect "$net" "$holder"
    docker network connect "$net" "$holder"            # any free address
  fi
  docker network disconnect "$net" "$aks" 2>/dev/null || true
  docker network connect --ip "$want_ip" "$net" "$aks"
fi

# 2. Start everything floci-az launched.
stopped=$(docker ps -a --filter "name=floci-az-lab-" --filter "status=exited" --format '{{.Names}}')
[ -n "$stopped" ] && docker start $stopped >/dev/null
docker ps --filter "name=floci-az-lab-" --format '  {{.Names}}  {{.Status}}'
