#!/usr/bin/env bash
# Monitoring on the shop's cluster, for the cutover gate's monitoring check.
#   bash monitoring.sh up        images in, shop on $TAG everywhere (its /metrics), Prometheus, Alertmanager, the pager
#   bash monitoring.sh forward   Prometheus on 127.0.0.1:19090 and Alertmanager on :19093 for the host (runs until killed)
#   bash monitoring.sh down      remove the monitoring namespace
# ONCALL_URL overrides the pager's address: a wrong one is how an alert fires and nobody hears it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
PROM=prom/prometheus:v3.15.1
AM=prom/alertmanager:v0.34.2
KUBECONFIG_HOST=$DRILL_WIN/eks-shop.kubeconfig

import() { # image file-stem [pinned: skip when the cluster has it]
  [ -z "${3:-}" ] || ! docker exec "$EKS" ctr -n k8s.io images ls -q | grep -qx "docker.io/$1" || return 0
  [ -f "$DRILL/$2.tar" ] || { docker image inspect "$1" >/dev/null 2>&1 || docker pull -q "$1" >/dev/null; docker save -o "$DRILL_WIN/$2.tar" "$1"; }
  docker cp "$DRILL_WIN/$2.tar" "$EKS:/tmp/$2.tar"
  docker exec "$EKS" ctr -n k8s.io images import "/tmp/$2.tar" >/dev/null
  docker exec "$EKS" rm -f "/tmp/$2.tar"
}

case "${1:-}" in
  up)
    stamp "images into the cluster"
    import "shop:$TAG" "shop-$TAG"
    import "$PROM" prometheus-v3.15.1 pinned
    import "$AM" alertmanager-v0.34.2 pinned
    stamp "every shop service on shop:$TAG (the monolith exports the stock check, catalog what it holds pending)"
    for d in $(k get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}' | awk '$2 ~ /^shop:/ {print $1}'); do
      k set image "deploy/$d" "*=shop:$TAG" >/dev/null
    done
    for d in $(k get deploy -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{" "}{end}'); do
      k rollout status "deploy/$d" --timeout=240s | tail -1
    done
    # The stock check reads what reservations hold. After the merge shop_app had no SELECT on them (catalog owned the
    # table), so the check could not run and ShopReconcileBlind went pending on the first scrape. Read only.
    [ "$(sql shop "select to_regclass('reservations') is not null")" = f ] || sql shop "grant select on reservations to shop_app"
    stamp "Prometheus, Alertmanager and the pager"
    hash=$(sha256sum "$HERE/monitoring.k8s.yaml" | cut -c1-12)
    sed -e "s/__TAG__/$TAG/g" -e "s/__CONFIG_HASH__/$hash-${ONCALL_URL:+custom}/g" \
        -e "s#__ONCALL_URL__#${ONCALL_URL:-http://alert-sink.monitoring:8080/}#g" "$HERE/monitoring.k8s.yaml" > "$DRILL/monitoring.rendered.yaml"
    docker cp "$DRILL_WIN/monitoring.rendered.yaml" "$EKS:/tmp/monitoring.yaml"
    docker exec "$EKS" kubectl apply -f /tmp/monitoring.yaml | cut -c1-70
    for d in prometheus alertmanager alert-sink; do
      docker exec "$EKS" kubectl -n monitoring rollout status "deploy/$d" --timeout=240s | tail -1
    done
    ;;
  forward)
    # The k3s API is published on 6501. The admin kubeconfig stays in .cache, outside the repo.
    docker exec "$EKS" cat /etc/rancher/k3s/k3s.yaml | sed 's#https://127.0.0.1:6443#https://127.0.0.1:6501#' > "$KUBECONFIG_HOST"
    # A port-forward holds one pod: a redeploy ends it, so each one reconnects until killed.
    for pair in prometheus:19090:9090 alertmanager:19093:9093; do
      IFS=: read -r svc local remote <<< "$pair"
      while true; do
        kubectl --kubeconfig "$KUBECONFIG_HOST" -n monitoring port-forward "svc/$svc" "$local:$remote" >/dev/null 2>&1 || true
        sleep 2
      done &
    done
    trap 'kill $(jobs -p) 2>/dev/null' EXIT
    wait
    ;;
  down)
    docker exec "$EKS" kubectl delete namespace monitoring --wait=false
    docker exec "$EKS" kubectl -n shop delete role,rolebinding prometheus-discovery --ignore-not-found
    ;;
  *) echo "usage: monitoring.sh up|forward|down" >&2; exit 2 ;;
esac
