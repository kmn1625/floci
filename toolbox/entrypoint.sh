#!/usr/bin/env bash
# Shared lab toolbox entrypoint. CLOUD=azure (default), aws or gcp.
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
#   gcp:   the same for *.googleapis.com and the metadata server; floci-gcp's own
#          names resolve to it.
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
elif [ "$CLOUD" = "gcp" ]; then
  if [ "${GCP_EGRESS_GUARD:-1}" = "1" ]; then
    # Google APIs and the GCE metadata server sink to 127.0.0.1. *.floci-gcp and
    # *.localhost.floci.io go to floci-gcp: GKE is reached as container.floci-gcp (host-mode
    # routing, gcp/lab/FINDINGS.md) and GCS virtual-hosted URLs use localhost.floci.io.
    FLOCI_GCP_HOST="${FLOCI_GCP_HOST:-floci-gcp}"
    ip=$(getent hosts "$FLOCI_GCP_HOST" | awk '{print $1; exit}')
    guard "googleapis.com googleusercontent.com gcr.io pkg.dev run.app appspot.com cloudfunctions.net
      firebaseio.com firebaseapp.com accounts.google.com metadata.google.internal" \
      "${ip:+address=/${FLOCI_GCP_HOST}/${ip}
address=/localhost.floci.io/${ip}}"
  fi
fi

exec "$@"
