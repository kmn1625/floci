#!/usr/bin/env bash
# Connect to the AKS cluster floci-az runs as a k3s container, and let it pull
# from the emulated ACR. Run on the Docker host (Git Bash / Linux / macOS).
#
#   scripts/aks-connect.sh <acr-name>        e.g. scripts/aks-connect.sh acrflocilabm9lr
#
# Why: floci-az 0.15.0 leaves the cluster in provisioningState "Creating", so
# listClusterUserCredential refuses to return a kubeconfig (FINDINGS.md F-16).
# Output: out/aks.kubeconfig, usable from the toolbox container.
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash: keep /etc/... container paths as-is

ACR="${1:?usage: aks-connect.sh <acr-name>}"
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$here/out"

aks=$(docker ps --filter "name=floci-az-lab-aks-" --format '{{.Names}}' | head -1)
reg=$(docker ps --filter "name=floci-az-lab-acr-registry" --format '{{.Names}}' | head -1)
[ -n "$aks" ] || { echo "no running AKS (k3s) container" >&2; exit 1; }
[ -n "$reg" ] || { echo "no running ACR registry container" >&2; exit 1; }

# 1. kubeconfig: k3s writes 127.0.0.1; point it at the container name on the compose
#    network and verify against the "kubernetes" SAN every k3s serving cert carries.
docker exec "$aks" cat /etc/rancher/k3s/k3s.yaml \
  | sed -e "s#https://127.0.0.1:6443#https://${aks}:6443#" \
        -e "s#^\(\s*\)server: \(.*\)#\1server: \2\n\1tls-server-name: kubernetes#" \
        -e "s#: default\$#: aks-floci#" \
  > "$here/out/aks.kubeconfig"
echo "wrote out/aks.kubeconfig (server https://${aks}:6443)"

# 2. <acr>.azurecr.io/<repo> -> http://<registry>:5000/<acr>/<repo> (floci-az stores each
#    registry's images under an <acr>/ prefix in one shared registry:2).
want=$(cat <<EOF
mirrors:
  ${ACR}.azurecr.io:
    endpoint:
      - "http://${reg}:5000"
    rewrite:
      "^(.*)\$": "${ACR}/\$1"
EOF
)
have=$(docker exec "$aks" sh -c 'cat /etc/rancher/k3s/registries.yaml 2>/dev/null' || true)
if [ "$have" != "$want" ]; then
  printf '%s\n' "$want" | docker exec -i "$aks" sh -c 'mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/registries.yaml'
  docker restart "$aks" >/dev/null
  echo "configured ${ACR}.azurecr.io mirror; restarted ${aks}"
else
  echo "registry mirror already configured"
fi
