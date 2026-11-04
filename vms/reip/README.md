# Moving the kubeadm cluster to new IPs

The lab cluster was built on Default Switch IPs, which change after a host restart. On 4 Nov 2026 it moved
to static IPs on the `k8s-lab` switch (k8s-cp1 172.30.31.168 → 10.77.0.10, workers → .11 and .12) without
a rebuild. New clusters from `vms/up.ps1` start on the static IPs, so this is only for an existing cluster.

1. As administrator: `vms/lab-network.ps1` creates the switch and the host address (10.77.0.1), and
   hot-adds a NIC on it to each running VM.
2. In each VM, write `/etc/netplan/60-k8s-lab.yaml` (the address, matched by the new NIC's MAC, no
   gateway) and bring it up with `ip link set eth1 up; ip addr add 10.77.0.X/24 dev eth1`.
   Do not run `netplan apply` on a running node. It re-runs DHCP on eth0 and drops any address added by
   hand. On 4 Nov that removed the API server's old IP from k8s-cp1 for a few minutes.
3. On the control plane, as root: `control-plane.sh OLD NEW`. It does the following:
   - backs up `/etc/kubernetes` and takes an etcd snapshot (`/root/reip-backup-*`)
   - moves the etcd peer URL
   - issues new apiserver and etcd certificates
   - rewrites the static pod manifests and kubeconfigs, sets the kubelet `--node-ip`, waits for the API
     server
   - updates the `kubeadm-config`, `kube-proxy` and `cluster-info` ConfigMaps and restarts kube-proxy
4. On each worker, as root: `worker.sh OLD NEW NODE_IP`.
5. Point Calico at the subnet. The operator then restarts calico-node:
   `kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"nodeAddressAutodetectionV4":{"firstFound":null,"cidrs":["10.77.0.0/24"]}}}}'`
6. Remove the old IP from the control plane and stop the VMs. Run `lab-network.ps1` again so it pins the
   NICs' MACs, because netplan matches on them. Then start the VMs.

Result on 4 Nov:
- All 3 nodes were Ready on 10.77.0.x, with Calico on the new addresses and Argo CD apps Healthy.
  hello-api returned 200.
- On the cold start in step 6, the Default Switch gave all 3 VMs new addresses. The cluster came back on
  its own in about 3 minutes.
- tigera-operator lost its leader lease while the API server moved, restarted, then recreated the
  host-network pods that still had their old IPs.
