#!/bin/bash
# control-plane.sh OLD NEW: move a kubeadm control plane (one node, stacked etcd) from OLD to NEW.
# Run as root on the control plane, with NEW already on an interface and OLD still reachable.
# Then run worker.sh on each worker and point Calico at the new subnet (vms/reip/README.md).
set -euo pipefail
OLD=$1 NEW=$2
K="kubectl --kubeconfig /etc/kubernetes/admin.conf"
PKI=/etc/kubernetes/pki
ip -4 -o addr | grep -q " $NEW/" || { echo "$NEW is not on this host"; exit 1; }
B=/root/reip-backup-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$B"

echo "1. backup to $B"
cp -a /etc/kubernetes /var/lib/kubelet/kubeadm-flags.env "$B/"
E="$K -n kube-system exec etcd-$(hostname) -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$PKI/etcd/ca.crt --cert=$PKI/etcd/server.crt --key=$PKI/etcd/server.key"
$E snapshot save /var/lib/etcd/reip-snapshot.db >/dev/null
mv /var/lib/etcd/reip-snapshot.db "$B/etcd-snapshot.db"

echo "2. etcd peer URL"
ID=$($E member list | awk -F', ' 'NR==1 {print $1}')
$E member update "$ID" --peer-urls="https://$NEW:2380"

echo "3. certificates with the new IP"
CFG=$B/kubeadm-reip.yaml
{ printf 'apiVersion: kubeadm.k8s.io/v1beta4\nkind: InitConfiguration\nlocalAPIEndpoint:\n  advertiseAddress: %s\nnodeRegistration:\n  name: %s\n---\n' "$NEW" "$(hostname)"  $K -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | sed "s/$OLD/$NEW/g"; } > "$CFG"
rm -f $PKI/apiserver.{crt,key} $PKI/etcd/server.{crt,key} $PKI/etcd/peer.{crt,key}
for c in apiserver etcd-server etcd-peer; do kubeadm init phase certs $c --config "$CFG"; done
openssl x509 -in $PKI/apiserver.crt -noout -ext subjectAltName | tail -1

echo "4. manifests, kubeconfigs, kubelet node IP"
sed -i "s/$OLD/$NEW/g" /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/kube-apiserver.yaml \
  /etc/kubernetes/*.conf
for f in /home/*/.kube/config /root/.kube/config; do [ -f "$f" ] && sed -i "s/$OLD/$NEW/g" "$f"; done
F=/var/lib/kubelet/kubeadm-flags.env
if grep -q -- '--node-ip=' $F; then sed -i -E "s/--node-ip=[^ \"]+/--node-ip=$NEW/" $F
else sed -i -E "s/^KUBELET_KUBEADM_ARGS=\"(.*)\"/KUBELET_KUBEADM_ARGS=\"\1 --node-ip=$NEW\"/; s/=\" /=\"/" $F; fi
cat $F
systemctl restart kubelet

echo "5. waiting for the API server on $NEW"
for i in $(seq 1 90); do curl -sk --max-time 2 "https://$NEW:6443/livez" | grep -q ok && break; sleep 2; done
until $K get --raw /readyz >/dev/null 2>&1; do sleep 2; done

echo "6. cluster ConfigMaps"
for cm in kube-system/kubeadm-config kube-system/kube-proxy kube-public/cluster-info; do
  $K -n "${cm%/*}" get cm "${cm#*/}" -o yaml | sed "s/$OLD/$NEW/g" | $K replace -f -
done
$K -n kube-system rollout restart ds kube-proxy
echo "done. Backup: $B"
