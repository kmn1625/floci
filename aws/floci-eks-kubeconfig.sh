#!/usr/bin/env bash
# floci-eks-kubeconfig.sh
# EKS kubeconfig workaround for Floci issue #1118.
#
# PROBLEM: `aws eks update-kubeconfig` generates a kubeconfig pointing at
# a Docker-internal address (e.g. https://172.17.0.2:6443) that is not
# reachable from the host. This causes `kubectl get nodes` to hang.
#
# FIX: Extract the kubeconfig directly from the k3s container via docker exec,
# then rewrite the server URL to use the host-mapped port.
#
# USAGE:
#   source floci-testing/floci-eks-kubeconfig.sh [CLUSTER_NAME]
#   # After sourcing: KUBECONFIG is set and kubectl works.
#
# Or run non-interactively to generate the file:
#   bash floci-testing/floci-eks-kubeconfig.sh dev-cluster /tmp/floci-kubeconfig.yaml
#   KUBECONFIG=/tmp/floci-kubeconfig.yaml kubectl get nodes
#
# ARGUMENTS:
#   $1 - CLUSTER_NAME: the EKS cluster name in Floci (default: dev-cluster)
#   $2 - OUTPUT_PATH: where to write the kubeconfig (default: /tmp/floci-kubeconfig.yaml)

set -euo pipefail

CLUSTER_NAME="${1:-dev-cluster}"
OUTPUT_PATH="${2:-/tmp/floci-kubeconfig.yaml}"
CONTAINER_NAME="floci-eks-${CLUSTER_NAME}"

echo "[floci-eks-kubeconfig] Cluster: ${CLUSTER_NAME}"
echo "[floci-eks-kubeconfig] Container: ${CONTAINER_NAME}"
echo "[floci-eks-kubeconfig] Output: ${OUTPUT_PATH}"

# Step 1: Verify the EKS container is running
if ! docker ps --format '{{.Names}}' | grep -qxF "${CONTAINER_NAME}"; then
    echo "[ERROR] Container '${CONTAINER_NAME}' is not running."
    echo "        Start Floci first: cd floci-testing && docker compose up -d"
    echo "        Then create an EKS cluster via terraform-agent or aws-agent."
    exit 1
fi

# Step 2: Find the host-mapped port for k3s API server (port 6443)
# docker port returns: 0.0.0.0:NNNNN
# We extract just the port number with sed.
HOSTPORT=$(docker port "${CONTAINER_NAME}" 6443 2>/dev/null | head -1 | sed -E 's/.*:([0-9]+)$/\1/')

if [[ -z "${HOSTPORT}" ]]; then
    echo "[ERROR] Port 6443 is not mapped on container '${CONTAINER_NAME}'."
    echo "        Floci EKS containers expose port 6443 dynamically."
    echo "        Confirm with: docker port ${CONTAINER_NAME}"
    exit 1
fi

echo "[floci-eks-kubeconfig] k3s API mapped to host port: ${HOSTPORT}"

# Step 3: Extract the kubeconfig from inside the container
# The k3s kubeconfig lives at /etc/rancher/k3s/k3s.yaml
docker exec "${CONTAINER_NAME}" cat /etc/rancher/k3s/k3s.yaml > "${OUTPUT_PATH}"

# Step 4: Rewrite the server URL from Docker-internal to localhost:<HOSTPORT>
# k3s.yaml contains: server: https://127.0.0.1:6443
# We replace it with: server: https://localhost:<HOSTPORT>
# Using sed in-place (-i flag; BSD sed on macOS needs '' arg, GNU sed does not)
if sed --version 2>/dev/null | grep -q GNU; then
    # GNU sed (Linux, Git Bash on Windows)
    sed -i -E "s#https://127\.0\.0\.1:6443#https://localhost:${HOSTPORT}#" "${OUTPUT_PATH}"
else
    # BSD sed (macOS)
    sed -i '' -E "s#https://127\.0\.0\.1:6443#https://localhost:${HOSTPORT}#" "${OUTPUT_PATH}"
fi

echo "[floci-eks-kubeconfig] Kubeconfig written to: ${OUTPUT_PATH}"
echo "[floci-eks-kubeconfig] Server URL rewritten to: https://localhost:${HOSTPORT}"

# Step 5: Set KUBECONFIG in current shell (only if sourced, not executed)
# shellcheck disable=SC2128
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export KUBECONFIG="${OUTPUT_PATH}"
    echo "[floci-eks-kubeconfig] KUBECONFIG exported: ${KUBECONFIG}"
fi

# Step 6: Verify kubectl connectivity
echo "[floci-eks-kubeconfig] Verifying kubectl connectivity..."
KUBECONFIG="${OUTPUT_PATH}" kubectl get nodes --request-timeout=10s
echo "[floci-eks-kubeconfig] SUCCESS: kubectl get nodes returned a node list."
