#!/usr/bin/env bash
# Deploy hello-api (k8s/hello-api/overlays/gke) to the lab GKE cluster the GKE way: endpoint
# and CA from the cluster API, a Google access token (the deployer's) as the bearer token.
# Run inside the toolbox:
#
#   docker compose --profile tools run --rm toolbox bash scripts/gke-deploy.sh
#
# floci-gcp advertises the k3s container name, which its certificate does not cover, so TLS is
# verified against the name it does cover (FINDINGS G-23).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER="$(terraform -chdir=terraform output -raw gke_cluster)"
SA="flocilab-deployer@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com"
token=$(curl -sf -X POST "${FLOCI_GCP_ENDPOINT}/v1/projects/-/serviceAccounts/${SA}:generateAccessToken" \
  -H "Authorization: Bearer ${GOOGLE_OAUTH_ACCESS_TOKEN}" -H "Content-Type: application/json" \
  -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"],"lifetime":"900s"}' | jq -r .accessToken)

cluster=$(curl -sf -H "Authorization: Bearer ${token}" -H "Host: container.floci-gcp:4588" \
  "${FLOCI_GCP_ENDPOINT}/v1/projects/${GOOGLE_CLOUD_PROJECT}/locations/us-central1/clusters/${CLUSTER}")
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
jq -r .masterAuth.clusterCaCertificate <<<"$cluster" | base64 -d > "$work/ca.crt"

export KUBECONFIG="$work/kubeconfig"
kubectl config set-cluster gke --server="https://$(jq -r .endpoint <<<"$cluster")" \
  --certificate-authority="$work/ca.crt" --embed-certs=true --tls-server-name=kubernetes >/dev/null
kubectl config set-credentials deployer --token="$token" >/dev/null
kubectl config set-context gke --cluster=gke --user=deployer >/dev/null
kubectl config use-context gke >/dev/null

kubectl apply -k /k8s/hello-api/overlays/gke
kubectl -n hello rollout status deploy/hello-api --timeout=300s
kubectl -n hello get pods -o wide
