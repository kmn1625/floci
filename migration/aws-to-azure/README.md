# Drill: AWS to Azure, and back

A live shop moves between two emulated clouds while customers keep shopping, then moves back. It starts where
[the on-prem drill](../onprem-to-aws/README.md) ended, so the same database, files and cluster are now the old system.
The question is the same: does a write a customer was told succeeded survive both trips?

| Part | AWS side (Floci 2.3.0) | Azure side (floci-az 0.15.0) |
|---|---|---|
| Database | RDS: real PostgreSQL 16.15 | Flexible Server: real PostgreSQL 17.11 |
| Files | S3 | Blob Storage, through the real Azure SDK |
| App | EKS: real k3s | AKS: real k3s |
| Secret | Secrets Manager | Key Vault |
| Between them | A shared Docker network, standing in for a VPN or peering | |
| Traffic | `shop-edge`, an nginx standing in for DNS or a global load balancer | |

## Result of the last run

| | |
|---|---|
| Confirmed writes through the whole journey | 587 |
| Of those, created on Azure and brought back | 299 orders; 31 files came back to S3 |
| **Lost, changed or impossible to check** | **0** |
| Refused during the two freezes, and only then | 305 |
| Database comparison during each freeze | 10 of 10 |
| Files hashed against the database | 672 of 672 |
| Writes stopped | 115 s forward, 86 s back |

The times come from a shared laptop with another job using half the CPU. The same scripts took 22 s forward on a
quieter host and 177 s back on a busier one, so do not read them as an estimate.

The cutover gate passed assessment, data, files, rollback and target, and **refused** the cutover: nothing here set
up monitoring on the target or a human approval. The evidence was not faked to get a pass.

## What went wrong on the way

The first run looked like a success: 22 seconds, 0 writes lost, every health check green. Then:

| Trap | What happened |
|---|---|
| Green health, broken uploads | Every upload failed on Azure while `/ready` and orders stayed green. The image had the Azure SDK but not the Azure code, and `/ready` only touches the database |
| Unknown config fell through | `STORAGE=azure` on a build that did not know the word meant local disk. The app now refuses to start |
| A stop left the app frozen | The check blocked the rollback, printed advice and exited, so writes stayed down. A stop now unfreezes the side that still holds everything |
| A safety check blocked the way back | "Target older than source" protects a forward move and stopped the rollback from 17 to 16. It now has to be stated: `--rolling-back` |
| A setting that was not set | Terraform accepted `wal_level = logical` and reported success. The server still said `replica` |
| A leftover from the last drill | The on-prem rollback left an inactive replication slot on RDS, the fault its own rule warns about, and no check noticed. The data check now does |
| A name the target refuses | The secret `shop/db` is not a legal Key Vault name. `migration-cloud-map.py` finds this from the state |
| An ETag that means nothing | A Blob ETag is an opaque id, so copies are proved by hashing the bytes |

Both new safeguards then proved themselves on real failures. The storage proof ran against the broken pods and stopped
before freezing anything. Unfreezing fired twice: when a rollback hit a missing image, and when replication was switched
off on purpose. The next order went through.

## Not tested

- A real cloud. Latency, egress cost, VPN limits and real downtime are all absent: both clouds share one Docker network.
- Identity. floci-az accepts any storage key, so managed identity and Blob permissions prove nothing here. The app used a
  key, which is not what you would run on real Azure.
- DNS. The switch is an nginx reload, so TTLs and cached answers are not part of this.
- Moving the image through registries: it was loaded into each cluster directly.
- Secret rotation, messaging, functions, identity: `migration-cloud-map.py` lists them as rework or redesign, and only 3 of
  its resource types have been moved in a drill.
- Size. The database is about 12 MB. Checksums read every row.
- Finishing the job: the drill ends back on AWS, so decommissioning is untested.

## Run it

Needs the AWS lab and floci-az running. `rds.name`, the passwords and `az.json` live in `.cache/migrate-drill`, outside the repo.

```bash
terraform -chdir=terraform apply       # through the azure toolbox; the cluster comes from a PUT, see below
bash prepare.sh                        # link the clouds, replicate
bash deploy.sh                         # same image on both, AWS first
bash edge.sh start
python ../onprem-to-aws/load.py run --url http://127.0.0.1:18080 --seconds 900 --out run.jsonl &
bash cutover.sh
bash rollback.sh
python ../onprem-to-aws/load.py check --url http://127.0.0.1:18080 --log run.jsonl
bash reset-drill.sh                    # AWS live, Azure an empty replica again
```

`azurerm` cannot read an AKS cluster back from floci-az (F-16), so the cluster comes from
`PUT .../managedClusters/aks-shop?api-version=2024-09-01`.
