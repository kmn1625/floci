#!/usr/bin/env bash
# terraform in terraform/ as the deployer service account (created by ../bootstrap).
# Run inside the toolbox:  docker compose --profile tools run --rm toolbox scripts/tf.sh plan
#
# The google provider's impersonate_service_account always calls the real
# iamcredentials.googleapis.com and ignores iam_credentials_custom_endpoint (FINDINGS G-10),
# so the token is minted here, as `gcloud auth print-access-token --impersonate-service-account`
# would. The external token only mints it; IAM enforcement evaluates the deployer.
set -euo pipefail

SA="${DEPLOYER_SA:-flocilab-deployer@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com}"
token=$(curl -sf -X POST "${FLOCI_GCP_ENDPOINT}/v1/projects/-/serviceAccounts/${SA}:generateAccessToken" \
  -H "Authorization: Bearer ${GOOGLE_OAUTH_ACCESS_TOKEN}" -H "Content-Type: application/json" \
  -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"],"lifetime":"3600s"}' | jq -r .accessToken)
if [ -z "$token" ] || [ "$token" = "null" ]; then
  echo "tf.sh: could not mint a token for ${SA} (run ../bootstrap first)" >&2
  exit 1
fi
GOOGLE_OAUTH_ACCESS_TOKEN="$token" exec terraform -chdir=terraform "$@"
