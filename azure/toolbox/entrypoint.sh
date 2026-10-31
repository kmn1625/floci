#!/usr/bin/env bash
# 1. Trust floci-az's self-signed certificate (regenerated on every fresh data volume).
# 2. Azure egress guard: floci-az returns real Azure hostnames for data planes
#    (vaultUri https://<kv>.vault.azure.net, storage http://<acct>.blob.core.windows.net,
#    ACR <name>.azurecr.io). Docker's DNS resolves those to real Azure, so clients
#    would leave the machine. Here every Azure domain resolves to 127.0.0.1 and
#    ports 80/443 are forwarded to floci-az, which routes by Host header and whose
#    certificate covers *.vault.azure.net and *.azurecr.io.
set -euo pipefail

FLOCI_AZ_HOST="${FLOCI_AZ_HOST:-floci-az}"
FLOCI_AZ_PORT="${FLOCI_AZ_PORT:-4577}"
AZURE_DOMAINS="core.windows.net vault.azure.net managedhsm.azure.net azurecr.io windows.net azure.net
  azure.com microsoftonline.com azconfig.io azure-api.net azurewebsites.net azurecontainerapps.io
  azure-devices.net servicebus.windows.net database.windows.net documents.azure.com"

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
  upstream=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
  {
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "server=${upstream}"
    echo "filter-AAAA"   # address= below is IPv4; without this, AAAA answers leak real Azure IPv6
    for d in $AZURE_DOMAINS; do echo "address=/${d}/127.0.0.1"; done
  } > /etc/dnsmasq.d/azure-guard.conf
  dnsmasq --conf-file=/etc/dnsmasq.d/azure-guard.conf
  echo "nameserver 127.0.0.1" > /etc/resolv.conf

  for p in 80 443; do
    socat "TCP-LISTEN:${p},fork,reuseaddr,bind=127.0.0.1" "TCP:${FLOCI_AZ_HOST}:${FLOCI_AZ_PORT}" 2>/dev/null &
  done
fi

exec "$@"
