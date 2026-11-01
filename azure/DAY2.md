# Day-2 operations on the Azure lab, run through the devops-project SaaS

2026-11-01, branch `day2/azure-ops`, floci-az 0.15.0, azurerm 4.81.0. The question: once infrastructure
exists, how does the SaaS handle the next change, drift, and incidents, without breaking anything?

- **Applied:** only safe changes, through the SaaS flow.
- **Planned only:** risky changes, to see whether the SaaS stops them; then reverted.
- **Drift:** simulated with direct ARM calls, as if someone had used the portal.
- **Fixes:** devops-project `b893a25`.

## How a change ran

`devops-pipeline.ps1` runs Terraform on the host, but this lab needs the toolbox (TLS trust, egress guard).
So `scripts/saas-plan.sh` produces in the toolbox the files the pipeline would: `tfplan.binary`, `plan.json`,
`terraform-outputs.json`, plus a refresh-only `drift.json`. The SaaS gates then ran on the host:

- `terraform-plan-gate.py --stage plan` (and `--stage converge` after apply)
- `iac-guardrail-chain.py`
- `iac-loop.py` (checkov), with `--baseline` after the fix
- `drift-checker.py`
- `post-deploy-auditor.py`
- `devops-operator.py --dry-run`

`expected-state.yaml` describes each scenario's intended change and resets to "no changes" between scenarios.

## What happened, before and after the fixes

| # | Scenario | Before (SaaS as it was) | After `b893a25` |
|---|---|---|---|
| S0 | **Incident:** a restart lost 11 control-plane resources (F-32), 27 to recreate | Plan gate PASS in dev and prod; drift checker PASS 4/4 (outputs come from state); auditor FAIL only because `az` was missing; operator flagged it for the wrong reason | Drift checker FAILs on each resource "deleted outside Terraform"; prod plan gate blocks `[drift]` until triaged |
| S0 | **Recovery** | Runbook: apply recreates the parents; the surviving blob container, queue, Key Vault secret and key needed `terraform import` | Same; the plan is then clean |
| S0 | **Hidden outage:** Postgres `fqdn` became `localhost`, Redis container gone, ARM "Succeeded" | Not seen by any gate; only `tests/smoke.py` failed | Still only app-level smoke tests see it. Run them before and after every change |
| S1 | Routine: new subnet, HTTPS-from-VNet rule, `CostCenter` tag | All PASS. The tag touched **18 resources**; floci-az rejected the Key Vault secret PATCH (F-25) and Postgres hung (F-33). Drift checker didn't notice 17 modifies beyond the 1 expected | Drift checker FAILs on unexpected modifies when `extra_modify_ok: false` |
| R1 | SSH from the Internet | Guardrail P0, checkov | Same |
| R1 | Postgres firewall 0.0.0.0–255.255.255.255 | Only checkov (CKV2_AZURE_26), buried among 39 existing findings | Guardrail P0; checkov baseline shows it as new |
| R1 | **Owner role for the workload identity** | **Nothing**: no guardrail, no checkov finding, plan gate PASS | Guardrail `privileged_iam` P0; plan gate warns in dev, blocks in staging and prod |
| R1 | Storage TLS 1.0 and public blobs | **Absent from the plan** (lab `ignore_changes`); only checkov | checkov baseline lists them as new. The masking `ignore_changes` stays a review point |
| R1 | Public blob container | checkov only | checkov baseline, new finding |
| R2 | **Storage account replaced (Premium)**, data lost | Plan gate PASS in dev and staging; prod "Run with -Force", a flag that didn't exist | `[data-loss]` blocks in every environment; `--approve data-loss="<ticket>"` is the logged way through |
| R2 | Postgres 16 → 17 (major, no downgrade) | Not flagged | `[major-upgrade]` warns in dev, blocks in staging and prod |
| S4 | Storage LRS → GRS | "Apply complete", but the cloud kept LRS (F-34); nothing noticed | `--stage converge` FAILs: the post-apply plan isn't empty |
| S5 | Postgres storage 32 → 64 GB | Applied; the update hangs in `Creating` (F-33) | Same (emulator) |
| S6 | **Portal: RDP from `*` added to the NSG** | Plan gate PASS (prod too), drift checker PASS, operator "PASS … no change from baseline" | Drift checker FAILs ("changed outside Terraform (security_rule)"); prod gate blocks; operator reports the regression with the resource |
| S6 | Portal: Postgres firewall `portal-allow-all` | **Invisible** to everything, Terraform included (unmanaged resource) | `unmanaged-check.py` reports it as P0 (verified live against floci-az) |
| S7 | k8s: `cluster-admin` for group `devs`, wildcard role, Secret reads | Only checkov's indirect bind/escalate checks; our guardrails PASS | RBAC guardrail FAILs each one unless annotated `devops.io/approved-privilege` |

Also fixed:
- Checkov's 40-line feedback cap hid 6 of 46 findings, which made a diff look like fixes.
- Missing CLIs now read as SKIP, not FAIL.
- The Key Vault URI is no longer passed where a vault name is expected.
- Normalisation noise (`description: null → ""`) is no longer drift.

## Still open

- **Done with the owner's OK:** Redis was replaced through the SaaS flow. The plan gate blocked `[data-loss]` until
  `--approve data-loss="..."`; then apply, converge gate PASS, smoke `redis PING -> PONG`. The S6 rogue
  `portal-allow-all` firewall rule was deleted (only `vnet-only` remains).
- **Postgres is still unreachable:** after the restart its `fqdn` is `localhost` (F-32), so smoke `postgres` fails.
  Fixing it from the emulator side would mean replacing a server that holds data, so it waits for the owner.
- **The pipeline can't target a toolbox-only environment.** `devops-pipeline.ps1` has no way to run Terraform
  elsewhere; the lab uses `scripts/saas-plan.sh`.
- **Unmanaged resources:** now covered for Azure by `tools/unmanaged-check.py`. Its first run found three real
  orphans (SQL server F-18, MySQL server F-22, AKS F-16), now listed in `terraform/.unmanaged-ignore`. The AWS and
  GCP collectors come with those phases.

## Re-run

```bash
cd azure
docker compose --profile tools run --rm -T toolbox bash scripts/saas-plan.sh
cd ../../devops-project
python tools/terraform-plan-gate.py --work-dir ../floci/azure/terraform --env prod --stage plan
python tools/drift-checker.py       --work-dir ../floci/azure/terraform --env dev
python tools/iac-loop.py            --work-dir ../floci/azure/terraform   # uses terraform/checkov-baseline.txt
python tools/unmanaged-check.py     --work-dir ../floci/azure/terraform --arm-endpoint https://localhost:4577 --insecure
```
