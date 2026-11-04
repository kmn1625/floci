#!/bin/bash
# stop.sh NAME: stop the load and the timeline, copy the load log out of the pod, remove the pod and its
# ConfigMap and NetworkPolicy, then print the summary and the timeline's changes.
set -eu
N=$1; D=/root/drills; HERE=$(cd "$(dirname "$0")" && pwd)
K="kubectl --kubeconfig /etc/kubernetes/admin.conf"
touch $D/$N.load.stop
$K -n hello exec drill-load -- touch /out/$N.load.stop; sleep 3
$K -n hello exec drill-load -- cat /out/$N.load > $D/$N.load
$K -n hello delete pod/drill-load configmap/drill-load networkpolicy/drill-load --wait=false >/dev/null
python3 "$HERE/summarize.py" $D/$N.load
echo "--- timeline (changes only)"; awk '{l=$0; sub(/^[^ ]+ /,"",l); if (l!=p) print; p=l}' $D/$N.timeline | cut -c1-230
