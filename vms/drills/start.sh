#!/bin/bash
# start.sh NAME: load through the hello-api Service + a 2 s timeline of the Deployment and its Argo CD app.
# The load runs in a pod on a worker, away from hello-api's pods: on the control plane it starved the
# controller-manager (DRILLS.md D-07). The pod is in namespace hello, which hello-api's NetworkPolicy admits.
# The timeline runs here, detached (multipass exec hangs on long-running output).
# Run as root on k8s-cp1; stop with stop.sh NAME.
set -eu
N=$1; D=/root/drills; HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p $D; rm -f $D/$N.*
K="kubectl --kubeconfig /etc/kubernetes/admin.conf"
IP=$($K -n hello get svc hello-api -o jsonpath='{.spec.clusterIP}')
IMAGE=docker.io/library/python:3.13-slim@sha256:ae14d4ce8771606477a81446e7ef429edd6762305fc50c84507c1041fa8285d1
$K -n hello delete pod drill-load --ignore-not-found --wait
$K -n hello create configmap drill-load --from-file=load.py="$HERE/load.py" --dry-run=client -o yaml | $K apply -f -
$K apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: drill-load, namespace: hello, labels: {purpose: drill}}
spec:
  podSelector: {matchLabels: {app: drill-load}}
  policyTypes: [Egress]
  egress:
    - to: [{podSelector: {matchLabels: {app: hello-api}}}]
      ports: [{port: 8080, protocol: TCP}]
---
apiVersion: v1
kind: Pod
metadata: {name: drill-load, namespace: hello, labels: {app: drill-load, purpose: drill}}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm: {topologyKey: kubernetes.io/hostname, labelSelector: {matchLabels: {app: hello-api}}}
  securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: load
      image: $IMAGE
      # Stays up after load.py ends so stop.sh can copy the log out.
      command: [sh, -c, 'python3 /drill/load.py $IP /out/$N.load; exec sleep 600']
      env: [{name: PYTHONDONTWRITEBYTECODE, value: "1"}]
      resources: {requests: {cpu: 200m, memory: 64Mi}, limits: {cpu: "1", memory: 128Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: drill, mountPath: /drill, readOnly: true}, {name: out, mountPath: /out}]
  volumes:
    - {name: drill, configMap: {name: drill-load}}
    - {name: out, emptyDir: {}}
EOF
$K -n hello wait --for=condition=Ready pod/drill-load --timeout=180s >/dev/null
setsid nohup bash -c "while [ ! -f $D/$N.load.stop ]; do
  echo \"\$(date -u +%H:%M:%S) \$($K -n hello get deploy hello-api -o jsonpath='gen={.metadata.generation}/{.status.observedGeneration} upd={.status.updatedReplicas} ready={.status.readyReplicas} unavail={.status.unavailableReplicas} {.status.conditions[?(@.type==\"Progressing\")].reason}') | argo \$($K -n argocd get application hello-api -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}' | cut -c1-30) | pods \$($K -n hello get pods -l app=hello-api --no-headers 2>/dev/null | awk '{printf \"%s:%s:%s:%s \", substr(\$1,11), \$2, \$3, \$4}')\"
  sleep 2; done > $D/$N.timeline 2>&1" >/dev/null 2>&1 < /dev/null &
echo "started $N at $(date -u +%H:%M:%S) against $IP from $($K -n hello get pod drill-load -o jsonpath='{.spec.nodeName}')"
