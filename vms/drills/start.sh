#!/bin/bash
# start.sh NAME: load through the hello-api Service + a 2 s timeline of the Deployment and its Argo CD app,
# both detached (multipass exec hangs on long-running output). Run as root on k8s-cp1; stop with stop.sh NAME.
set -eu
N=$1; D=/root/drills; HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p $D; rm -f $D/$N.*
K="kubectl --kubeconfig /etc/kubernetes/admin.conf"
IP=$($K -n hello get svc hello-api -o jsonpath='{.spec.clusterIP}')
setsid nohup python3 "$HERE/load.py" "$IP" $D/$N.load >/dev/null 2>&1 < /dev/null &
setsid nohup bash -c "while [ ! -f $D/$N.load.stop ]; do
  echo \"\$(date -u +%H:%M:%S) \$($K -n hello get deploy hello-api -o jsonpath='gen={.metadata.generation}/{.status.observedGeneration} upd={.status.updatedReplicas} ready={.status.readyReplicas} unavail={.status.unavailableReplicas} {.status.conditions[?(@.type==\"Progressing\")].reason}') | argo \$($K -n argocd get application hello-api -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}' | cut -c1-30) | pods \$($K -n hello get pods --no-headers 2>/dev/null | awk '{printf \"%s:%s:%s:%s \", substr(\$1,11), \$2, \$3, \$4}')\"
  sleep 2; done > $D/$N.timeline 2>&1" >/dev/null 2>&1 < /dev/null &
sleep 1; echo "started $N at $(date -u +%H:%M:%S) against $IP"
