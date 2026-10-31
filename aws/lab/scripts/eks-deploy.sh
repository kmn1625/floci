#!/usr/bin/env bash
# Deploy hello-api (k8s/hello-api/overlays/eks, image from the lab ECR) to the lab EKS cluster.
#
# The IAM path (scripts/eks_kubeconfig.py) is the real one, but Floci 2.3.0 rejects every EKS
# token while signature validation is on (FINDINGS A-19), so this applies with the k3s admin
# kubeconfig inside the cluster container. That bypasses EKS IAM auth; the ECR pull, PSA,
# RBAC, NetworkPolicy and probes are still exercised by the cluster.
#
#   bash scripts/eks-deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NODE="floci-aws-eks-flocilab-eks"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT

MSYS_NO_PATHCONV=1 docker compose --profile tools run --rm -T toolbox \
  kubectl kustomize /k8s/hello-api/overlays/eks 2>/dev/null > "$manifest"
grep -q '^kind: Deployment' "$manifest" || { echo "eks-deploy: kustomize rendered nothing" >&2; exit 1; }

kube() { MSYS_NO_PATHCONV=1 docker exec -i "$NODE" kubectl "$@"; }
kube apply -f - < "$manifest"
kube -n hello rollout status deploy/hello-api --timeout=300s
kube -n hello get pods -o wide
