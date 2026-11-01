# Day-2 operations on the AWS lab, run through the devops-project SaaS

2026-11-01, branch `day2/aws-ops`, Floci 2.3.0, aws provider 6.71.0. Same method as `azure/DAY2.md`:
`scripts/saas-plan.sh` writes the pipeline's artefacts in the toolbox (`tfplan.binary`, `plan.json`,
`terraform-outputs.json`, `state.json`, refresh-only `drift.json`), and the SaaS gates run on the host.

- **Applied:** safe changes only.
- **Planned only:** risky changes, then reverted.
- **Drift:** made with boto3 directly, as from the console.
- **SaaS fixes:** devops-project `dbbaada`, `f4a5127` and the commit after this report. The Azure fixes were
  already in.

## Results

| # | Scenario | What the SaaS did | Fixed here |
|---|---|---|---|
| S0 | **Restart.** RDS endpoint moved (A-20); EKS `ACTIVE` but k3s dead (A-21); EC2 `pending` | Drift for the endpoint, `instance_state` and `latest_restorable_time` **blocked prod** although Terraform can't undo any of them | `latest_restorable_time` and other volatile attributes are never drift; changes the plan keeps are `observed` (warn). The endpoint warning tells you to check consumers |
| S0 | Orphans | `unmanaged-check` (new AWS collector) listed the EKS cluster SG and node instance, Floci's Lambda bucket and a sample ECR repo | Resources tagged by EKS / Auto Scaling / CloudFormation are skipped; the two emulator leftovers go in `.unmanaged-ignore` |
| S1 | Routine: `reports` queue and an in-VPC metrics rule | All gates PASS; applied; converge PASS. Smoke afterwards: 3 failures from the restart (A-20, A-21, Lambda 502). Smoke wasn't run before the change, so whether S1 caused them is inferred, not proven | Run `-HealthCmd` before a change. The AWS smoke run here proved why |
| R | DynamoDB key change (replace) | `[data-loss]` BLOCK | (Azure fixes) |
| R | RDS 16 → 17 | `[major-upgrade]` BLOCK | (Azure fixes) |
| R | `AdministratorAccess` on the Lambda role | `[privileged]` BLOCK, `privileged_iam` P0, CKV_AWS_274 | (Azure fixes) |
| R | SSH from `0.0.0.0/0` | `no_open_sg` P0, CKV_AWS_24 | (Azure fixes) |
| R | **S3 public access block off; RDS `publicly_accessible`** | Only checkov (CKV_AWS_53/54/17), as on Azure | New `no_public_data` guardrail (P0); approval `# devops:approved-exposure <reason>` |
| R | RDS drift line | "this plan reverts it" because the plan updated RDS for an unrelated reason | Drift is judged per attribute: "reverts X" only when the plan sets X back |
| D | **Console: RDP from `0.0.0.0/0` on the app SG** (its rules are separate resources) | Plan gate and drift checker: **only `observed` WARN** ("kept: ingress"); `unmanaged-check`: P0 with the rule ID | A kept change to security attributes (ingress/egress, rules, policies, CIDRs, public flags) is drift and blocks prod. Rule revoked after triage |
| D | Console: `reports` queue deleted | "deleted outside Terraform; this plan recreates it", prod BLOCK; recreated | — |
| T1 | Console: bucket `flocilab-manual-exports` created | `unmanaged-check` P1 → `import` block + `-generate-config-out` (dropped `tags_all` and defaults) → `encrypt_at_rest` **P0 on the adopted bucket** → KMS encryption and public access block added in the same change → 1 import, 2 adds, converge PASS | — |
| T3a | `removed { destroy = false }` on the queue | `[forget]` BLOCK in prod; after apply `unmanaged-check` reports the queue | — |
| T3b | `terraform state rm` on the bucket | Plan: create the bucket (would collide) and replace its encryption and public-access block, flagged only as generic `[destroy]` | The finding now says the bucket "probably still exists but left the state (terraform state rm?); import it instead". Re-imported |
| T3 | Re-adopt the queue under a new address | Import with Floci's queue URL failed (A-22); the AWS URL form works | — |
| T4 | Bucket address renamed with `moved` (dependents reference it) | `state: 1 move`, 0 changes | — |
| — | A failed plan left the old `plan.json` | The gate judged the stale plan | The gate refuses a `plan.json` older than the code |

## End state

- **Plan:** no changes; converge PASS.
- **Checks:** `unmanaged-check` PASS; drift checker PASS.
- **Code:** `reports.tf` (queue `report_queue`, metrics rule) and `adopted.tf` (bucket `exports` with encryption
  and a public access block).

## Still open

- **The restart outages are still there:** the RDS endpoint is unreachable (A-20), EKS's k3s isn't running (A-21),
  EC2 is `pending`, and API → Lambda returns 502. These are emulator restart effects, not repaired here.
- **CLI `terraform import` / `state rm` change state with no plan.** Only the PreToolUse prompt stands in the
  way; use import and removed blocks.
- **No GCP collector in `unmanaged-check` yet.**

## Re-run

```bash
cd aws/lab
docker compose --profile tools run --rm -T toolbox bash scripts/saas-plan.sh
cd ../../../devops-project
export AWS_ACCESS_KEY_ID=floci AWS_SECRET_ACCESS_KEY=floci AWS_DEFAULT_REGION=us-east-1
python tools/terraform-plan-gate.py --work-dir ../floci/aws/lab/terraform --env prod --stage plan
python tools/drift-checker.py       --work-dir ../floci/aws/lab/terraform --env dev
python tools/iac-loop.py            --work-dir ../floci/aws/lab/terraform --only checkov
python tools/unmanaged-check.py     --work-dir ../floci/aws/lab/terraform --aws-endpoint http://localhost:4566
```
