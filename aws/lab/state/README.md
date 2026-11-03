# State and data recovery drills (AWS lab, Floci 2.3.0, Terraform 1.16.6)

What happens to Terraform state and a database when things go wrong, and whether devops-project
catches it. Run on 2026-11-03. The fixes are in devops-project (`tools/recovery.py`, plan gate
`fresh-state`, bash gate `-lock=false`, `state_backend` locking check, runbooks `state-lock-stuck`,
`state-restore`, `db-restore`).

## Layout

- `bootstrap/`: the state backend. A versioned, encrypted S3 bucket `flocilab-tfstate` with public access
  blocked, plus the DynamoDB table `flocilab-tfstate-lock`. Local state.
- `app/`: a small workload (SQS queues + one SSM parameter) whose state is in that bucket.
  - `backend-dynamodb.hcl`: the layout devops-project used before this run.
  - `backend-lockfile.hcl`: S3-native `use_lockfile`.
  - SQS queues take about 25 s to create, which gives time to race or kill an apply.
- `scripts/break_state.py`: corrupts, deletes or rolls back the remote state for the drills. It refuses
  any endpoint that is not the local emulator.

```bash
docker compose -f aws/lab/docker-compose.yml up -d floci-lab
TB="docker compose -f aws/lab/docker-compose.yml --profile tools run --rm -T toolbox sh -c"
MSYS_NO_PATHCONV=1 $TB 'cd state/bootstrap && terraform init && terraform apply -auto-approve'
MSYS_NO_PATHCONV=1 $TB 'cd state/app && terraform init -backend-config=backend-lockfile.hcl && terraform apply -auto-approve'
```

## Results

| # | Drill | What happened | Caught by (after this run) |
|---|---|---|---|
| T1 | Two applies at once (DynamoDB lock) | The second fails: `Error acquiring the state lock`, ConditionalCheckFailedException | Terraform itself |
| T1b | The second run uses `-lock=false` | Both runs write the state. The queue `state-lab-work-6` exists but is in no state, and the next plan says **"No changes"** | bash gate asks on `-lock=false`; `unmanaged-check` lists the queue |
| T2 | Apply killed during create | The lock stays (the next run fails). 3 queues exist that the state does not list. After `force-unlock` the re-apply adopted them silently (CreateQueue with the same attributes returns the existing queue) | `recovery.py state` shows lock owner and age; `state-lock-stuck` runbook |
| T3a | State truncated (DynamoDB lock) | `state data in S3 does not have the expected content`. The message says to store the new checksum, which is the checksum of the **broken** file | `recovery.py state` warns not to; restoring the last version fixes it |
| T3b | State deleted (DynamoDB lock) | Checksum error, with the hint to "remove the Digest" (that leads to an empty state) | `recovery.py state` → LAST GOOD → `--restore` |
| T4 | Migrate to `use_lockfile`, race two applies | Works on Floci: the `.tflock` object and a 412 PreconditionFailed for the second run. The deprecation warning is gone | — |
| T4b | State deleted (`use_lockfile`) | **Silent: "Plan: 11 to add"** | plan gate `fresh-state` (blocks staging/prod); `recovery.py state` |
| T4c | Older version copied on top (`use_lockfile`) | **Silent: "Plan: 3 to add"**. A truncated file fails loudly (`Unsupported state file format`) | `recovery.py state`: the serial went back |
| T5 | RDS: probe row → snapshot → second row → `DELETE` → restore | The snapshot restore has the first row. Both restores came up in subnet group `default` and security group `sg-00000000`, and **publicly accessible** (the source was private, on its own SG) | `recovery.py db --restored` flags it; `recovery.py db --target` prints the call that keeps the settings, verified OK |
| T5b | Point-in-time restore to before the `DELETE` | Floci restored the **current** (empty) table | Emulator gap A-24, not a product bug |

Also found:
- devops-project's `backend-*.hcl` were gitignored, so a fresh clone had none, although README and
  ONBOARDING tell you to edit them. They are tracked now; they hold placeholders only.
- devops-project's prod backend told users to `terraform workspace select prod`. With a per-env key,
  that reads an empty state at `env:/prod/...`.

## Cleanup still in the lab

These were created by the drills and are still running:
- RDS instances `flocilab-pg-snap`, `flocilab-pg-pitr` and `flocilab-pg-restored`, each with its own Postgres container
- snapshots `flocilab-pg-t5` (taken before the probe table existed) and `flocilab-pg-t5b`
- the `restore_probe` table in `flocilab-pg`
- the state-lab queues and the backend bucket and table

Removing any of them needs the owner's OK.
