#!/usr/bin/env bash
# Pause or resume the observability stack on the kubeadm cluster to free CPU/RAM.
#
#   bash vms/observability-pause.sh pause
#   bash vms/observability-pause.sh resume
#
# Pause: turn off Argo CD auto-sync (root app-of-apps + the observability apps), otherwise
# self-heal scales everything straight back; then scale every component to zero.
# Prometheus/Alertmanager are set through their CRs (the operator owns the StatefulSets);
# node-exporter (DaemonSet) gets a nodeSelector that matches no node.
# Resume: re-enable auto-sync on root. It re-applies the child Applications from Git
# (auto-sync included) and those re-apply the charts — every replica back to what Git says.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$(cd "$(dirname "$0")" && pwd)/.keys/kubeconfig}"
NS=observability
APPS="kube-prometheus-stack loki tempo alloy dashboards"

case "${1:-}" in
  pause)
    for app in root $APPS; do
      kubectl -n argocd patch application "$app" --type json \
        -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null 2>&1 || true
    done
    echo "auto-sync off: root $APPS"
    kubectl -n "$NS" patch prometheus kps-prometheus --type merge -p '{"spec":{"replicas":0}}' >/dev/null 2>&1 || true
    kubectl -n "$NS" patch alertmanager kps-alertmanager --type merge -p '{"spec":{"replicas":0}}' >/dev/null 2>&1 || true
    kubectl -n "$NS" patch daemonset kps-prometheus-node-exporter --type merge \
      -p '{"spec":{"template":{"spec":{"nodeSelector":{"floci-lab/paused":"true"}}}}}' >/dev/null
    kubectl -n "$NS" scale deployment --all --replicas=0 >/dev/null
    kubectl -n "$NS" scale statefulset loki tempo --replicas=0 >/dev/null
    ;;
  resume)
    kubectl -n argocd patch application root --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
    kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    echo "root auto-sync on; Argo CD restores the observability apps from Git (a few minutes)"
    ;;
  *)
    echo "usage: observability-pause.sh pause|resume" >&2
    exit 2
    ;;
esac
kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '{print "  " $1, $2, $3}' || true
