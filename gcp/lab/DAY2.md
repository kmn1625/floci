# Day-2 operations on the GCP lab, run through the devops-project SaaS

2026-11-01, branch `day2/gcp-ops`, floci-gcp 0.12.0, google provider 8.9.0, IAM enforcement on (Terraform runs
as the deployer through `scripts/tf.sh`). Same method as the Azure and AWS reports. This run started the way
`runbooks/after-restart.md` says: health first, then refresh-only drift, then the unmanaged check, and only then
changes.

## Results

| # | Scenario | What the SaaS did |
|---|---|---|
| Restart triage | Health check before any change: GKE unreachable. k3s had exited because the Cloud Run container took its pinned bridge IP (G-25) | `runbook.py` resolves the signal to `cluster-unhealthy.md`. The shared `scripts/k3s_reclaim_ip.py` gave the address back; node `Ready`; smoke back to 9 pass, 8 known gaps |
| Restart triage | Refresh-only drift | Cloud SQL addresses changed (G-26) → `observed` (warn, check consumers). BigQuery `num_rows`, Cloud Run job counters and `etag` were noise and are now volatile |
| Restart triage | Unmanaged check (new GCP collector) | Found the G-09 orphan bucket, the leftover probe bucket and the deployer SA (managed by `bootstrap/`); all three listed in `.unmanaged-ignore` with reasons |
| R | Logs bucket renamed (replacement) | `[data-loss]` BLOCK |
| R | Cloud SQL `POSTGRES_16` → `POSTGRES_17` | `[major-upgrade]` BLOCK |
| R | `roles/owner` for the app SA | `[privileged]` BLOCK + `privileged_iam` P0 |
| R | SSH firewall from `0.0.0.0/0`; Cloud SQL authorized network `0.0.0.0/0` | `no_open_sg` P0 (both) |
| R | `allUsers` objectViewer on the artifacts bucket | `no_public_data` P0 |
| D | API: firewall `allow-rdp-any` created | Plan, drift checker and plan gate can't see it; **`unmanaged-check` P0**. Deleted after triage |
| D | API: `roles/owner` granted to the invoker SA in project IAM | Same: only **`unmanaged-check` P0 `iam_binding`**. Removed after triage |
| D | API: subscription `flocilab-orders-dlq` deleted | "deleted outside Terraform; this plan recreates it", prod BLOCK; recreated |
| T4 | Topic `orders_dlq` renamed to `dead_letter` with `moved` (subscription, dead-letter policy and IAM reference it) | `state: 1 move`, 0 changes |

No new gap in the plan gate or guardrails: every risky change was caught by the fixes made on Azure and AWS.
What GCP added: the unmanaged-check GCP collector, including project IAM admin bindings, and more volatile
attributes.

## End state

- **Health:** smoke 9 pass, 8 known gaps, 0 fail.
- **Checks:** converge PASS, drift PASS, unmanaged PASS.
- **New lab files:** `scripts/saas-plan.sh`, `scripts/recover-after-restart.py`, `terraform/expected-state.yaml`,
  `terraform/checkov-baseline.txt`, `terraform/.unmanaged-ignore`.

## Re-run

```bash
cd gcp/lab
python scripts/recover-after-restart.py                       # after any Docker restart
docker compose --profile tools run --rm -T toolbox bash scripts/saas-plan.sh
cd ../../../devops-project
export GOOGLE_OAUTH_ACCESS_TOKEN=$(curl -s -X POST "http://localhost:4588/v1/projects/-/serviceAccounts/flocilab-deployer@flocilab.iam.gserviceaccount.com:generateAccessToken" -H "Authorization: Bearer x" -H "Content-Type: application/json" -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' | python -c "import sys,json;print(json.load(sys.stdin)['accessToken'])")
python tools/terraform-plan-gate.py --work-dir ../floci/gcp/lab/terraform --env prod --stage plan
python tools/drift-checker.py       --work-dir ../floci/gcp/lab/terraform --env dev
python tools/unmanaged-check.py     --work-dir ../floci/gcp/lab/terraform --gcp-endpoint http://localhost:4588
```
