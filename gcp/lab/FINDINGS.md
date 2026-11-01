# floci-gcp findings

Behaviour found while driving `floci/floci-gcp:0.12.0` with Terraform (`hashicorp/google` 8.9.0) and REST /
`google-cloud-firestore` from the toolbox container (`CLOUD=gcp`), with `FLOCI_GCP_SERVICES_IAM_AUTHORIZATION_MODE=enforce`,
`FLOCI_GCP_PROJECTS_STRICT=true` and `FLOCI_GCP_LOCATIONS_STRICT=true`. Each entry: what happens, how it was verified,
and what the lab does about it. Re-test gated resources with `-var include_known_emulator_gaps=true`.

| ID | Area | Finding | Lab workaround |
|---|---|---|---|
| G-01 | Containers | **No Artifact Registry** (or any registry): the 24 services don't include `artifactregistry.googleapis.com`. Cloud Run and GKE pull through the host Docker daemon from public registries, so the "push to the cloud registry, deploy by digest" flow of the AWS and Azure labs can't be reproduced. | hello-api 0.2.0 comes from GHCR by digest (`sha256:06a03e37…`), the same digest as the ECR copy. |
| G-02 | Managed Kafka | `CreateCluster` throws `ClassCastException: String cannot be cast to Number` (`KafkaService.applyCapacityFromBody`) and returns 500. Terraform sends `capacityConfig.memoryBytes`/`vcpuCount` as JSON strings, which is how proto3 JSON encodes int64. Also happens in mock mode. | Cluster and topic gated. |
| G-03 | Terraform UX | For the unimplemented APIs below (G-02, G-04 to G-08), **apply never fails**: the resources sat at "Creating…"/"Still creating…" for 17 minutes with no error, while everything that `depends_on` them waited. A graceful interrupt is ignored; only a second one stops Terraform. | Gating; `timeout` on lab applies. |
| G-04 | KMS IAM | `getIamPolicy`/`setIamPolicy` on a crypto key or key ring returns 404 `CryptoKey not found: …/cryptoKeys/<key>:getIamPolicy`: the `:getIamPolicy` suffix is parsed as part of the key name. So `google_kms_crypto_key_iam_member` (service agents granted encrypt/decrypt for CMEK) can't be created. | Gated; CMEK users keep `depends_on` for real GCP. |
| G-05 | Cloud Tasks | gRPC only: REST `/v2/projects/…/queues` returns 404 (HTML). `google_cloud_tasks_queue` can't be created. | Gated. |
| G-06 | Firestore | No Firestore Admin REST API (`/v1/projects/…/databases` returns 404), so `google_firestore_database` can't be created. The gRPC data plane works on `(default)` without it. | Gated; smoke uses the data plane. |
| G-07 | Compute | `routers` returns 501 `Compute collection not implemented`, so Cloud Router and Cloud NAT can't be created. | Gated. |
| G-08 | Compute / strict | With `FLOCI_GCP_PROJECTS_STRICT=true`, the public image projects that floci-gcp documents (`debian-cloud`, …) are refused too: `GET …/debian-cloud/global/images/debian-12` returns 403. No Terraform VM can boot from a public image in strict mode. | VM gated; strict mode kept. |
| G-09 | IAM / GCS | In enforce mode, an external token (`GOOGLE_OAUTH_ACCESS_TOKEN`) counts as anonymous for GCS. A bucket it creates gets **no admin binding**, so right after creation Terraform's own read returns `403 storage.buckets.get`. The bucket is then unreadable and unmanageable by everyone, including a `roles/owner` service account. Pub/Sub, Secret Manager, IAM and Cloud Run let the same caller through (the bypass that floci-gcp documents). | `bootstrap/` creates a deployer service account; `scripts/tf.sh` runs the lab as it. The orphan `flocilab-logs` bucket stays in the emulator; the lab uses `flocilab-audit-logs`. |
| G-10 | Terraform provider | `impersonate_service_account` ignores `iam_credentials_custom_endpoint` and always calls `https://iamcredentials.googleapis.com` (the egress guard blocked it: `dial tcp 127.0.0.1:443`). This is a provider limitation, not floci-gcp. | `scripts/tf.sh` mints the token itself, like `gcloud auth print-access-token --impersonate-service-account`. |
| G-11 | Secret Manager | User-managed replication comes back as `userManaged: {}` (replica location and **CMEK key dropped**), which forces replacement on every plan. **Labels are never stored**: PATCH `updateMask=labels` returns 200 and nothing changes. | `ignore_changes = [replication, labels, terraform_labels, effective_labels]`. |
| G-12 | Pub/Sub | The topic's `kmsKeyName` is not stored, so the topic loses its CMEK key and plans always show an update. | `ignore_changes = [kms_key_name]`. |
| G-13 | Scheduler | The HTTP target's `oidcToken` is not stored. | `ignore_changes = [http_target[0].oidc_token]`. |
| G-14 | GCS | The bucket's `encryption.defaultKmsKeyName` and `logging` blocks are not stored, and **objects come back without `kmsKeyName`**. A test that "the bucket default CMEK applies" can't pass here. | `ignore_changes = [encryption, logging]`; smoke reports GAP. |
| G-15 | Scheduler / Eventarc | Neither can reach Cloud Run's generated URL `http://<svc>-<hash>.<region>.run.floci-gcp:4588` from inside floci-gcp. The Scheduler job fires with `dispatch failed: null` (status code 2). Eventarc logs `Failed to deliver Eventarc event N … ConnectException`. The same URL works from the toolbox, whose guard resolves `*.floci-gcp`. Likely fix, not yet tested: `FLOCI_GCP_SERVICES_CLOUDRUN_EXECUTION_URL_HOST_SUFFIX` set to a name floci-gcp itself resolves. | Smoke reports GAP for Scheduler; Eventarc checked by log. |
| G-16 | GCS / security | With `public_access_prevention = "enforced"`, a `setIamPolicy` granting `allUsers` `roles/storage.objectViewer` is **accepted** (GCP rejects it with 412). | Smoke reports GAP and restores the policy. |
| G-17 | GKE / security | The cluster is private (`enable_private_endpoint = true`, master authorized networks = the private subnet). floci-gcp **drops `enablePrivateEndpoint` and `masterAuthorizedNetworksConfig`** and publishes the API on the host at **`0.0.0.0:6550`**. Together with G-24, anyone who can reach the host gets cluster-admin. | Recorded. |
| G-18 | IAM Credentials | Service-account callers are evaluated (the invoker can't mint the deployer's token: 403), but **any external or anonymous token can mint a token for any service account**. floci-gcp documents this as not being a security boundary. | Smoke reports GAP. |
| G-19 | Cloud SQL | The instance has `ssl_mode = "ENCRYPTED_ONLY"`, but the PostgreSQL 16.14 container answers **only in plaintext**: `sslmode=require` fails with `server does not support SSL`. The app connects with the Secret Manager password over plaintext. | Smoke reports GAP. |
| G-20 | Cloud Run / IAM | Invocation is not IAM-checked (as floci-gcp documents): an **anonymous request gets 200** although only the invoker service account has `roles/run.invoker`. | Smoke reports GAP. |
| G-21 | Cloud Run / security | `ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"` is not enforced: the service answers on the host at `localhost:4588` with its `Host` header. | Recorded. |
| G-22 | Firebase Auth | The password policy works (a short password gets `WEAK_PASSWORD`), but ID tokens are **unsigned JWTs (`alg: none`)**, as documented, so token-verification code can't be tested. | Smoke reports GAP and deletes its user. |
| G-23 | GKE | The advertised endpoint is the k3s container name `floci-gcp-gke-<project>-<cluster>:6443`, which the API server certificate doesn't cover (it covers `kubernetes`, the container ID, …). A kubeconfig built from `endpoint` + `clusterCaCertificate`, which is what `gcloud container clusters get-credentials` does, fails TLS verification. | `scripts/gke-deploy.sh` verifies against `tls-server-name: kubernetes`. |
| G-24 | GKE / security | The token webhook maps **any non-empty bearer token to cluster-admin** (as documented): `kubectl auth can-i '*' '*'` with `not-a-google-token` returns `yes`. | Deploy still uses a real deployer token; smoke reports GAP. |

## Coverage (Terraform, google 8.9.0, floci-gcp 0.12.0)

66 resources converge, and 7 resource blocks (13 instances) are gated: Kafka cluster and topic (G-02), KMS IAM for the
6 service agents (G-04), Cloud Tasks queue (G-05), Firestore database (G-06), Cloud Router and NAT (G-07), and the VM (G-08).

What converges:
- **Project:** 17 project services.
- **IAM:** 3 workload service accounts plus the bootstrap deployer, project IAM members, a custom role, and Workload Identity binding.
- **KMS:** key ring and crypto key (90-day rotation).
- **Secrets:** Secret Manager secret, version and accessor binding.
- **Storage:** 2 GCS buckets (uniform access, public access prevention, versioning, CMEK, soft delete, lifecycle, access logging), objects, and bucket IAM.
- **BigQuery:** dataset (CMEK, access) and day-partitioned table.
- **Cloud SQL:** PostgreSQL 16 (CMEK, `ENCRYPTED_ONLY`, PITR backups, flags), database and user.
- **Pub/Sub:** 2 topics, a subscription with retry and dead-lettering, a DLQ subscription, and topic IAM.
- **Eventarc:** Pub/Sub → Cloud Run trigger.
- **Scheduler:** job with an OIDC target.
- **Logging and Monitoring:** log sink to GCS with its writer binding, and a custom metric descriptor.
- **Network:** VPC, private subnet with secondary ranges and flow logs, and 2 firewall rules (deny-all, IAP SSH).
- **GKE:** private cluster (Workload Identity, CMEK secrets, Calico network policy, release channel) and node pool.
- **Cloud Run:** v2 service (internal ingress, probes, limits), invoker IAM, and a v2 job.
- **Cloud Functions:** gen2 function with its source object.

## Data-plane smoke (`tests/smoke.py`)

`9 passed, 8 known emulator gaps, 0 failed`. Every call uses Floci-issued service-account tokens, so IAM enforcement is
what's being tested.
- **GCS:** versioning works; CMEK not applied (GAP G-14). Bucket IAM: the app can read, the invoker is denied, and the app can't write; but `allUsers` is accepted (GAP G-16).
- **Pub/Sub:** the app can publish, the invoker is denied, and pull/ack work. A message nacked 5 times moves to the DLQ.
- **KMS:** encrypt/decrypt round trip.
- **Secret Manager:** the app can read the secret; the invoker is denied.
- **IAM impersonation:** service-account callers are checked; external tokens aren't (GAP G-18).
- **BigQuery:** streaming insert, then a GoogleSQL `SUM` on DuckDB.
- **Cloud SQL:** reachable, plaintext only (GAP G-19).
- **Cloud Run:** the service answers; anonymous calls are allowed (GAP G-20). The job execution succeeds.
- **Scheduler:** GAP G-15.
- **Firestore:** set, update, query and delete.
- **Logging:** write and list, and the sink exports to GCS.
- **Monitoring:** custom metric written and read back.
- **Firebase Auth:** GAP G-22.
- **GKE:** GAP G-24.

## Containers: GHCR → Cloud Run and GKE

Cloud Run runs `hello-api` 0.2.0 by digest: `GET /` returns `{"env":"cloudrun","version":"0.2.0"}`.

`scripts/gke-deploy.sh` builds a kubeconfig the GKE way (endpoint and CA from the clusters API, a Google access token
for the deployer) and applies `k8s/hello-api/overlays/gke`, which annotates the KSA for Workload Identity. Verified:
- 2/2 pods Running.
- `GET /` through the API server proxy returns `{"env":"gke","version":"0.2.0"}`.
- Restricted Pod Security rejects a privileged pod.

## Load notes

- Managed Kafka runs in mock mode (Redpanda needs about 1 GB) and Compute Engine in its default mock mode.
- The AWS lab containers are stopped while this lab runs.
- Sidecar images are pinned, because floci-gcp defaults several of them to `:latest`.
