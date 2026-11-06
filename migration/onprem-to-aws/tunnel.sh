#!/usr/bin/env bash
# The way back needs on-prem to reach the cloud, and this firewall only allows the other direction, as
# many do. So the cloud side dials out and forwards two ports over SSH. A real migration would use the
# VPN or Direct Connect here, which has to carry traffic both ways for rollback to work at all.
#   bash tunnel.sh on | off
set -euo pipefail
export MSYS_NO_PATHCONV=1
DRILL=/d/devops-project/.cache/migrate-drill
NAME=shop-tunnel
case "$1" in
  on)
    [ -f "$DRILL/tunnel_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C migration-tunnel -f "$DRILL/tunnel_ed25519"
    pub=$(cat "$DRILL/tunnel_ed25519.pub")
    timeout 20 multipass exec onprem1 -- bash -c "grep -qF '$pub' ~/.ssh/authorized_keys || echo 'restrict,port-forwarding $pub' >> ~/.ssh/authorized_keys"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --restart unless-stopped --memory 32m --network lab_default \
      -v "D:/devops-project/.cache/migrate-drill/tunnel_ed25519:/key:ro" alpine:3.22 sh -c '
        apk add -q openssh-client && cp /key /tmp/k && chmod 600 /tmp/k
        exec ssh -N -i /tmp/k -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ExitOnForwardFailure=yes \
          -R 127.0.0.1:15432:floci-lab:7002 -R 127.0.0.1:14566:floci-lab:4566 ubuntu@10.77.0.20' >/dev/null
    ;;
  off) docker rm -f "$NAME" >/dev/null 2>&1 || true ;;
  *) echo "usage: tunnel.sh on|off" >&2; exit 2 ;;
esac
echo "tunnel $1"
