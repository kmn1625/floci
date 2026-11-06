# Drill: on-prem to AWS, and back

A small monolith moves from one VM to the emulated AWS lab while customers keep shopping, then moves back. The
question is not whether the copy works. It is whether a write a customer was told succeeded survives both trips.

| Part | Here | Stands in for |
|---|---|---|
| `onprem1` (10.77.0.20) | Ubuntu VM: nginx, gunicorn under systemd, local PostgreSQL 16, files on disk, cron | The old server |
| RDS | Real PostgreSQL 16 on Floci | Amazon RDS |
| S3, EKS | Floci S3, real k3s | Amazon S3, EKS |
| `shop-edge` | nginx | DNS or a load balancer |
| `shop-tunnel` | SSH dialled out from the cloud side | The VPN: Windows Firewall blocks the VM reaching the host |

`apps/shop` is deliberately awkward: a table with no primary key, sequences, uploads on local disk, a cron job, and
config naming `127.0.0.1`.

## Result of the last run

| | |
|---|---|
| Confirmed writes through the whole journey | 399 |
| Of those, created on AWS and brought home | 73 orders, 22 files |
| **Lost or changed** | **0** |
| Data check during the freeze | 10 of 10 |
| Files hashed against the database | 599 of 599 |
| Writes stopped, cutover | 36 s on a quiet host, 363 s with the check inside the freeze on a busy one |
| Writes stopped, rollback | 20 s and 104 s, same runs |

The times are from a shared laptop where every `docker exec` took seconds. Do not read them as an estimate.
The cutover gate passed assessment, data, files and rollback, and **refused** the cutover: nothing here set up
monitoring on the target or a human approval.

## What went wrong on the way

Each of these happened, and each is now a rule (`rules/migration.md` in devops-project).

| Trap | What happened |
|---|---|
| Truncated schema | A hung transfer cut the dump. Tables arrived, keys and indexes did not, replication stalled on one table, and nothing errored |
| No primary key | Publishing `audit_log` broke the nightly purge at once |
| Sequences | After a naive cutover 42 of 42 orders failed with `duplicate key`, with health checks green |
| Frozen database | `ALTER DATABASE ... read_only` also refused the command that undoes it |
| Sequence wound back | `setval` copied low values over the live source, and every order failed from then on |
| Wait that fell through | Rollback timed out, printed "behind by unknown", and carried on |
| Orphan files | The app writes the file first, so uploads that failed in a freeze left strays: 786 files for 610 rows |
| Read-only root filesystem | gunicorn's control socket default crashed the pods, and no startup probe made it worse |

## Not tested

- A real cloud. Nothing here measures real replication speed, RDS limits or downtime.
- DNS. The switch is an nginx reload, so TTLs and cached answers are not part of this.
- Moving the cron jobs. They stayed on `onprem1`, because the drill ends back there.
- Decommissioning the old server.
- Size. The database is 12 MB. Checksums read every row, which will not scale as it stands.

Floci gaps: `rds.logical_replication` is ignored, so the drill used `ALTER SYSTEM`, and the admin is a superuser,
which real RDS does not give you.

## Run it

Needs the `k8s-lab` switch (`vms/lab-network.ps1`) and about 4 GB of RAM. Everything else stays stopped.

```bash
powershell -ExecutionPolicy Bypass -File migration/onprem-to-aws/onprem-up.ps1   # onprem1
docker compose -f aws/lab/docker-compose.yml up -d floci-lab
# terraform/ creates the target. prepare-source.sh, source-share.sh and tunnel.sh open the paths.
bash migration/onprem-to-aws/edge.sh start
bash migration/onprem-to-aws/reset-drill.sh                                      # target empty, replicating
python migration/onprem-to-aws/load.py run --url http://127.0.0.1:18080 --seconds 900 --out run.jsonl &
bash migration/onprem-to-aws/cutover.sh
bash migration/onprem-to-aws/rollback.sh
python migration/onprem-to-aws/load.py check --url http://127.0.0.1:18080 --log run.jsonl
```

The scripts read their passwords from `.cache/migrate-drill`, outside the repo.
