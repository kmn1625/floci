#!/usr/bin/env bash
# Produce the files the devops-project pipeline gates read, from inside the toolbox, as the
# deployer service account (scripts/tf.sh mints its token; IAM enforcement is on).
#
#   docker compose --profile tools run --rm -T toolbox bash scripts/saas-plan.sh [plan args...]
#
# Writes in terraform/ (git-ignored; plan.json, state.json and terraform-outputs.json hold
# sensitive values in clear text): tfplan.binary, plan.json, terraform-outputs.json, state.json,
# and drift.json (refresh-only plan: real cloud state vs Terraform state).
set -euo pipefail
cd /work
tf() { bash scripts/tf.sh "$@"; }

tf fmt -check -recursive
tf validate -no-color
tf plan -input=false -no-color -out=tfplan.binary "$@"
tf show -json tfplan.binary > terraform/plan.json
tf output -json > terraform/terraform-outputs.json
tf show -json > terraform/state.json
tf plan -input=false -no-color -refresh-only -out=drift.binary > /dev/null
tf show -json drift.binary > terraform/drift.json
rm -f terraform/drift.binary
echo "saas-plan: wrote tfplan.binary, plan.json, terraform-outputs.json, state.json, drift.json"
