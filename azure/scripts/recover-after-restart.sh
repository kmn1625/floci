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

# 3. If floci-az started its children itself first (`docker start floci-az`), the AKS container may have booted once on
#    another address and registered the Node with it. Back on its own address, k3s's network policy controller then
#    exits: "failed to find interface with specified node ip" (10 Nov, F-38). The API server answers for about 3 s
#    before that, long enough to correct the Node's address.
if [ -n "$aks" ] && [ -n "$want_ip" ]; then
  sleep 20
  if [ -z "$(docker ps -q --filter "name=$aks")" ] \
     && docker logs --tail 5 "$aks" 2>&1 | grep -q 'failed to find interface with specified node ip'; then
    node=$(docker inspect -f '{{.Config.Hostname}}' "$aks")
    docker start "$aks" >/dev/null
    for _ in $(seq 1 60); do
      if docker exec "$aks" kubectl patch node "$node" --subresource=status --type=json -p \
           "[{\"op\":\"test\",\"path\":\"/status/addresses/0/type\",\"value\":\"InternalIP\"},{\"op\":\"replace\",\"path\":\"/status/addresses/0/address\",\"value\":\"$want_ip\"}]" \
           >/dev/null 2>&1; then
        echo "AKS node address set back to $want_ip"
        break
      fi
      sleep 0.3
    done
  fi
fi
# The other children may come back on each other's addresses too (10 Nov: Postgres and the registry swapped), and the
# drills reach them by address. Compare with what the drill was given before trusting a failed connection.
docker ps --filter "name=floci-az-lab-" --format '  {{.Names}}  {{.Status}}'
docker network inspect "$net" --format '{{range .Containers}}  {{.Name}} {{.IPv4Address}}{{println}}{{end}}'
