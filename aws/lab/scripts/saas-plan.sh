#!/usr/bin/env bash
# Produce the files the devops-project pipeline gates read, from inside the toolbox
# (the AWS lab signs as Floci's deployer and resolves *.amazonaws.com to nothing there;
# devops-pipeline.ps1 runs terraform on the host, so its plan phase cannot target this lab).
#
#   docker compose --profile tools run --rm -T toolbox bash scripts/saas-plan.sh [plan args...]
#
# Writes in terraform/ (all git-ignored; plan.json and terraform-outputs.json hold
# sensitive values in clear text):
#   tfplan.binary, plan.json     what devops-pipeline.ps1 -Phase plan produces
#   terraform-outputs.json       what -Phase apply captures after apply
#   drift.json                   refresh-only plan: real cloud state vs Terraform state
#   state.json                   terraform show -json, for unmanaged-check.py
set -euo pipefail
cd /work/terraform

terraform fmt -check -recursive
terraform validate -no-color
terraform plan -input=false -no-color -out=tfplan.binary "$@"
terraform show -json tfplan.binary > plan.json
terraform output -json > terraform-outputs.json
terraform show -json > state.json   # devops-project tools/unmanaged-check.py

terraform plan -input=false -no-color -refresh-only -out=drift.binary > /dev/null
terraform show -json drift.binary > drift.json
rm -f drift.binary
echo "saas-plan: wrote tfplan.binary, plan.json, terraform-outputs.json, state.json, drift.json"
