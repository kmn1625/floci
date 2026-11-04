#!/bin/bash
# worker.sh OLD_CP NEW_CP NODE_IP: point a kubeadm worker at the control plane's new IP and pin its own node IP.
# Run as root on each worker after control-plane.sh.
set -euo pipefail
OLD=$1 NEW=$2 NODE_IP=$3
ip -4 -o addr | grep -q " $NODE_IP/" || { echo "$NODE_IP is not on this host"; exit 1; }
B=/root/reip-backup-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$B"
F=/var/lib/kubelet/kubeadm-flags.env
cp -a /etc/kubernetes/kubelet.conf $F "$B/"
sed -i "s/$OLD/$NEW/g" /etc/kubernetes/kubelet.conf
if grep -q -- '--node-ip=' $F; then sed -i -E "s/--node-ip=[^ \"]+/--node-ip=$NODE_IP/" $F
else sed -i -E "s/^KUBELET_KUBEADM_ARGS=\"(.*)\"/KUBELET_KUBEADM_ARGS=\"\1 --node-ip=$NODE_IP\"/; s/=\" /=\"/" $F; fi
cat $F
systemctl restart kubelet
echo "done. Backup: $B"
