#!/usr/bin/env bash
# Copy an image into the lab's ECR repository (Floci) and print its digest-pinned URI.
#
# Floci names the registry <account>.dkr.ecr.<region>.localhost:4566 and routes by that Host
# header; Docker Desktop's daemon cannot resolve *.localhost names (FINDINGS A-12), so a plain
# `docker push` fails. crane runs on the lab network with the ECR name mapped to floci-lab and
# logs in with a real GetAuthorizationToken password, so ECR auth is exercised as in AWS.
#
#   bash scripts/ecr-push.sh [source-image] [tag]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-ghcr.io/kmn1625/hello-api@sha256:06a03e3721de009766ee788296f23c7438547f73406f8f852eacf1bf8aa279f9}"
TAG="${2:-0.2.0}"
CRANE="gcr.io/go-containerregistry/crane/debug:v0.20.3"
NET="lab_default"  # floci-lab also joins the VPC bridges Floci creates; the compose network is the stable one
IP="$(docker inspect floci-lab --format "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}")"

toolbox() { MSYS_NO_PATHCONV=1 docker compose --profile tools run --rm -T toolbox bash -c "$1" 2>/dev/null | grep -v -E "Container |Volume"; }

REPO="$(toolbox 'terraform -chdir=terraform output -raw ecr_repository_url')"
HOST="${REPO%%/*}"
PASSWORD="$(toolbox 'pip install -q --root-user-action=ignore boto3 >/dev/null 2>&1; python3 -c "
import base64, boto3
d = boto3.client(\"ecr\").get_authorization_token()[\"authorizationData\"][0]
print(base64.b64decode(d[\"authorizationToken\"]).decode().split(\":\", 1)[1])"' | tail -1)"

printf '%s' "$PASSWORD" | MSYS_NO_PATHCONV=1 docker run --rm -i --network "$NET" --add-host "${HOST%%:*}:${IP}" \
  --entrypoint sh "$CRANE" -c "
    crane auth login --insecure '$HOST' -u AWS --password-stdin >/dev/null &&
    crane copy --insecure '$SRC' '$REPO:$TAG' >/dev/null &&
    echo '$REPO@'\$(crane digest --insecure '$REPO:$TAG')"
