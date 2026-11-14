#!/bin/bash
# Cascading-overload drill (README.md). Runs from the host with the lab kubeconfig.
#
#   drill.sh image                     build hello-api, import it into containerd on the workers
#   drill.sh up BACKEND ROUTER [N]     BACKEND = broken|protected, ROUTER = naive|safe, N routers (default 4)
#   drill.sh trigger [STAGGER_S]       the network change: bump netconfig's generation
#   drill.sh watch NAME                record pods, endpoints and restarts every 2 s to out/NAME.timeline
#   drill.sh collect NAME              router logs -> out/NAME.routers, then summarize
#   drill.sh down                      delete the namespace
#   drill.sh run NAME BACKEND ROUTER [STAGGER_S]   all of the above for one configuration
#   drill.sh recover [N]               shed load, wait for Ready backends, ramp routers back to N
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
export KUBECONFIG=${KUBECONFIG:-$ROOT/vms/.keys/kubeconfig}
NS=outage-drill
IMG=hello-api:0.3.0-drill
PY=docker.io/library/python:3.13-slim@sha256:ae14d4ce8771606477a81446e7ef429edd6762305fc50c84507c1041fa8285d1
OUT=$HERE/out; mkdir -p "$OUT"
k() { kubectl -n $NS "$@"; }

case "${1:-}" in
image)
  # Compile on 1 CPU with the module and build caches in Docker volumes: a plain `docker build`
  # took 2+ host cores for 10 min and starved the lab VMs (README, finding O-08), and a Go cache
  # on a Windows bind mount stalls `go vet` for 20+ min.
  GO=golang:1.27.3-alpine3.24@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb
  MSYS_NO_PATHCONV=1 docker run --rm --cpus 1 -v hello-gomod:/go/pkg/mod -v hello-gocache:/root/.cache/go-build \
    -v "$(cd "$ROOT/apps/hello-api" && pwd -W):/src:ro" -v "$(cd "$OUT" && pwd -W):/out" $GO \
    sh -c 'cp -r /src /w && cd /w && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=0.3.0-drill" -o /out/hello-api .'
  printf 'FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab\nCOPY hello-api /hello-api\nUSER 65532:65532\nENTRYPOINT ["/hello-api"]\n' > "$OUT/Dockerfile"
  docker build -q -t $IMG "$OUT" && rm "$OUT/Dockerfile" "$OUT/hello-api"
  docker save $IMG -o "$OUT/hello-api.tar"
  export MSYS_NO_PATHCONV=1 # Git Bash would rewrite /home/ubuntu/... into a Windows path
  for n in k8s-w1 k8s-w2; do
    # multipass transfer takes a relative path (a C: path reads as an instance name)
    (cd "$OUT" && multipass transfer hello-api.tar $n:/home/ubuntu/hello-api.tar)
    multipass exec $n -- sudo ctr -n k8s.io images import /home/ubuntu/hello-api.tar
    multipass exec $n -- rm /home/ubuntu/hello-api.tar
  done
  rm "$OUT/hello-api.tar"
  ;;

up)
  BACKEND=$2 ROUTER=$3 N=${4:-4}
  kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace $NS purpose=drill --overwrite >/dev/null
  if ! k get secret backend-tls >/dev/null 2>&1; then
    # 4096-bit RSA: one handshake costs the 200m backend about as much as a busy front end's
    # handshake costs a real server, so the lab's handshake capacity is small and easy to exceed.
    # Relative file names: Git Bash must not rewrite them, and must not rewrite -subj /CN=...
    tmp=$(mktemp -d)
    (cd "$tmp" && MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:4096 -nodes -days 7 -subj /CN=backend.$NS \
      -keyout tls.key -out tls.crt 2>&1 | grep -v '^[.+*]' || true
     k create secret tls backend-tls --cert=tls.crt --key=tls.key)
    rm -rf "$tmp"
  fi
  TLS_ENV='[{name: APP_ENV, value: drill}, {name: TLS_PORT, value: "8443"}, {name: TLS_CERT_FILE, value: /tls/tls.crt}, {name: TLS_KEY_FILE, value: /tls/tls.key}'
  if [ "$BACKEND" = broken ]; then
    # As many front ends ship: probes on the same HTTPS port clients use, default 1 s timeout,
    # no admission control.
    ENV="$TLS_ENV]"
    PROBES='
          livenessProbe: {httpGet: {path: /healthz, port: 8443, scheme: HTTPS}, periodSeconds: 10}
          readinessProbe: {httpGet: {path: /readyz, port: 8443, scheme: HTTPS}, periodSeconds: 5}'
  else
    # Handshakes and requests over the limit are refused cheaply; probes go to a plain admin
    # port outside both limits; liveness only restarts a pod that is silent for a minute.
    ENV="$TLS_ENV, {name: MAX_HANDSHAKES, value: \"8\"}, {name: MAX_INFLIGHT, value: \"32\"}, {name: ADMIN_PORT, value: \"8081\"}]"
    PROBES='
          livenessProbe: {httpGet: {path: /healthz, port: 8081}, periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 6}
          readinessProbe: {httpGet: {path: /readyz, port: 8081}, periodSeconds: 5, timeoutSeconds: 2}'
  fi
  k create configmap router-code --from-file=router.py="$HERE/router.py" --dry-run=client -o yaml | k apply -f -
  k apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: netconfig}
data: {generation: "1", stagger_s: "0"}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: router}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: read-netconfig}
rules: [{apiGroups: [""], resources: [configmaps], resourceNames: [netconfig], verbs: [get]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: router-read-netconfig}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: read-netconfig}
subjects: [{kind: ServiceAccount, name: router}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: backend}
spec:
  podSelector: {matchLabels: {app: backend}}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {matchLabels: {app: router}}}], ports: [{port: 8443}]}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: router}
spec:
  podSelector: {matchLabels: {app: router}}
  policyTypes: [Egress]
  egress:
    - to: [{podSelector: {matchLabels: {app: backend}}}]
      ports: [{port: 8443}]
    - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
      ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
    - to: [{ipBlock: {cidr: 10.77.0.10/32}}]
      ports: [{port: 6443}]
---
apiVersion: v1
kind: Service
metadata: {name: backend}
spec:
  selector: {app: backend}
  ports: [{name: https, port: 443, targetPort: 8443}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend}
spec:
  replicas: 3
  selector: {matchLabels: {app: backend}}
  template:
    metadata: {labels: {app: backend}}
    spec:
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 5
      topologySpreadConstraints:
        - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway, labelSelector: {matchLabels: {app: backend}}}
      securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: backend
          image: $IMG
          imagePullPolicy: Never
          env: $ENV
          resources: {requests: {cpu: 100m, memory: 32Mi}, limits: {cpu: 200m, memory: 64Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: tls, mountPath: /tls, readOnly: true}]$PROBES
      volumes: [{name: tls, secret: {secretName: backend-tls}}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: router}
spec:
  replicas: 0 # scaled up below, after the backends are Ready
  selector: {matchLabels: {app: router}}
  template:
    metadata: {labels: {app: router}}
    spec:
      serviceAccountName: router
      terminationGracePeriodSeconds: 2
      securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: router
          image: $PY
          command: [python3, -u, /code/router.py]
          env:
            - {name: UPSTREAM, value: backend.$NS.svc.cluster.local}
            - {name: MODE, value: $ROUTER}
            - {name: THREADS, value: "24"}
            - {name: RATE, value: "${RATE:-0.5}"}
            - {name: PYTHONDONTWRITEBYTECODE, value: "1"}
          resources: {requests: {cpu: 100m, memory: 64Mi}, limits: {cpu: 300m, memory: 128Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: code, mountPath: /code, readOnly: true}]
      volumes: [{name: code, configMap: {name: router-code}}]
EOF
  k rollout status deploy/backend --timeout=180s
  # Start the routers one by one: all at once against cold backends is already the outage
  # (run R0 in README.md), and every run must start from the same healthy steady state.
  for i in $(seq 1 "$N"); do
    k scale deploy/router --replicas="$i" >/dev/null
    k rollout status deploy/router --timeout=180s >/dev/null
    sleep 15
  done
  k get pods -o wide --no-headers | awk '{print $1, $2, $3, $4, $7}'
  ;;

trigger)
  g=$(k get configmap netconfig -o jsonpath='{.data.generation}')
  k patch configmap netconfig --type merge -p "{\"data\":{\"generation\":\"$((g + 1))\",\"stagger_s\":\"${2:-0}\"}}"
  echo "network change: generation $((g + 1)), stagger ${2:-0}s, at $(date -u +%H:%M:%S)"
  ;;

watch)
  N=$2
  rm -f "$OUT/$N.timeline" "$OUT/$N.stop"
  while [ ! -f "$OUT/$N.stop" ]; do
    eps=$(k get endpointslice -l kubernetes.io/service-name=backend -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{" "}{end}' 2>/dev/null)
    pods=$(k get pods -l app=backend --no-headers 2>/dev/null | awk '{printf "%s:%s:%s:%s ", substr($1,length($1)-4), $2, $3, $4}')
    echo "$(date -u +%s) ready=$(echo "$eps" | grep -o true | wc -l)/$(echo "$eps" | wc -w) $pods"
    sleep 2
  done > "$OUT/$N.timeline"
  ;;

collect)
  N=$2
  touch "$OUT/$N.stop"
  : > "$OUT/$N.routers"
  for p in $(k get pods -l app=router -o name); do k logs "$p" >> "$OUT/$N.routers"; done
  python "$HERE/summarize.py" "$OUT/$N.routers" "$OUT/$N.timeline"
  ;;

down)
  kubectl delete namespace $NS --wait=true --ignore-not-found
  ;;

recover)
  # The runbook's recovery, measured (R5): shed load first, wait for every backend to be Ready,
  # then bring the callers back one at a time. Rolling back the trigger is not a step: it is over.
  N=${2:-4}
  echo "$(date -u +%T) shed: routers -> 1"
  k scale deploy/router --replicas=1 >/dev/null
  until [ "$(k get deploy backend -o jsonpath='{.status.readyReplicas}')" = 3 ]; do sleep 5; done
  echo "$(date -u +%T) backends 3/3 Ready"
  sleep 30
  for i in $(seq 2 "$N"); do
    k scale deploy/router --replicas="$i" >/dev/null
    echo "$(date -u +%T) routers -> $i"
    sleep 30
  done
  ;;

run)
  # run NAME BACKEND ROUTER [STAGGER_S]: fresh namespace, steady state, change, 4 min, collect.
  NAME=$2
  bash "$HERE/drill.sh" down
  bash "$HERE/drill.sh" up "$3" "$4"
  bash "$HERE/drill.sh" watch "$NAME" &
  sleep 60
  bash "$HERE/drill.sh" trigger "${5:-0}"
  sleep 240
  bash "$HERE/drill.sh" collect "$NAME"
  wait
  ;;

*) sed -n '2,10p' "$0"; exit 1 ;;
esac
