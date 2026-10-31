#!/usr/bin/env bash
# Shared lab toolbox entrypoint. CLOUD=azure (default) or aws.
#
# Egress guard: the emulators are local, but SDKs/providers default to real cloud
# endpoints, so a missed endpoint override would leave the machine.
#   azure: floci-az returns real Azure hostnames for data planes (vaultUri, storage,
#          ACR). Every Azure domain resolves to 127.0.0.1 and :80/:443 are forwarded
#          to floci-az, which routes by Host header; its cert covers *.vault.azure.net
#          and *.azurecr.io (azure/FINDINGS.md F-01). The floci-az cert is trusted.
#   aws:   every *.amazonaws.com name resolves to 127.0.0.1 with nothing listening,
#          so a call that misses its http://floci-lab:4566 override fails fast
#          instead of reaching real AWS.
set -euo pipefail

CLOUD="${CLOUD:-azure}"

guard() {  # $1 = space-separated domains sunk to 127.0.0.1, $2 = extra dnsmasq lines
  local upstream
  upstream=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
  {
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "server=${upstream}"
    echo "filter-AAAA"   # address= below is IPv4; AAAA answers would leak real IPv6
    for d in $1; do echo "address=/${d}/127.0.0.1"; done
    [ -n "${2:-}" ] && echo "$2"
  } > /etc/dnsmasq.d/cloud-guard.conf
  dnsmasq --conf-file=/etc/dnsmasq.d/cloud-guard.conf
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
}

if [ "$CLOUD" = "azure" ]; then
  FLOCI_AZ_HOST="${FLOCI_AZ_HOST:-floci-az}"
  FLOCI_AZ_PORT="${FLOCI_AZ_PORT:-4577}"
  for _ in $(seq 1 30); do
    if curl -sf "http://${FLOCI_AZ_HOST}:${FLOCI_AZ_PORT}/_floci/tls-cert" -o /usr/local/share/ca-certificates/floci-az.crt; then
      break
    fi
    sleep 2
  done
  if [ ! -s /usr/local/share/ca-certificates/floci-az.crt ]; then
    echo "toolbox: could not fetch the floci-az certificate" >&2
    exit 1
  fi
  update-ca-certificates >/dev/null 2>&1
  if [ "${AZURE_EGRESS_GUARD:-1}" = "1" ]; then
    guard "core.windows.net vault.azure.net managedhsm.azure.net azurecr.io windows.net azure.net
      azure.com microsoftonline.com azconfig.io azure-api.net azurewebsites.net azurecontainerapps.io
      azure-devices.net servicebus.windows.net database.windows.net documents.azure.com"
    for p in 80 443; do
      socat "TCP-LISTEN:${p},fork,reuseaddr,bind=127.0.0.1" "TCP:${FLOCI_AZ_HOST}:${FLOCI_AZ_PORT}" 2>/dev/null &
    done
  fi
elif [ "$CLOUD" = "aws" ]; then
  if [ "${AWS_EGRESS_GUARD:-1}" = "1" ]; then
    # Host-prefixed calls (S3 Control puts the account in the name: 000000000000.floci-lab)
    # must reach the emulator too: *.floci-lab -> floci-lab's address (resolved before the
    # guard replaces this container's resolver).
    FLOCI_AWS_HOST="${FLOCI_AWS_HOST:-floci-lab}"
    ip=$(getent hosts "$FLOCI_AWS_HOST" | awk '{print $1; exit}')
    guard "amazonaws.com amazonaws.com.cn aws.amazon.com api.aws" "${ip:+address=/${FLOCI_AWS_HOST}/${ip}}"
  fi
fi

exec "$@"
