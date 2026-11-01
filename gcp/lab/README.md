# GCP lab on floci-gcp 0.12.0

```bash
cd gcp/lab
docker compose up -d                                            # floci-gcp on :4588 (API only, no web UI)
docker compose --profile tools build toolbox
docker compose --profile tools run --rm toolbox sh -c "terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply"
docker compose --profile tools run --rm toolbox sh -c "terraform -chdir=terraform init"
docker compose --profile tools run --rm toolbox bash scripts/tf.sh plan -out=tfplan
docker compose --profile tools run --rm toolbox bash scripts/tf.sh apply tfplan
```

IAM enforcement is on, so the lab doesn't run Terraform with an anonymous token. `bootstrap/` creates the
`flocilab-deployer` service account, and `scripts/tf.sh` runs the lab root with a Floci-issued token for it.
Strict projects and locations are on too, so typos in a project or region fail as they would on GCP.

The toolbox resolves every Google API name to 127.0.0.1, so a call that misses its endpoint override fails
instead of reaching Google.

66 resources across 20 services converge. Resources the emulator can't serve yet sit behind
`-var include_known_emulator_gaps=true`; [FINDINGS.md](FINDINGS.md) explains each one.

```bash
docker compose --profile tools run --rm toolbox sh -c "pip install -q google-cloud-firestore && python3 tests/smoke.py"
docker compose --profile tools run --rm toolbox bash scripts/gke-deploy.sh   # k8s/hello-api/overlays/gke
```

floci-gcp has no Artifact Registry (G-01). Cloud Run and GKE pull `ghcr.io/kmn1625/hello-api` 0.2.0 by digest.
`gke-deploy.sh` builds the kubeconfig the GKE way: endpoint and CA from the clusters API, plus a Google access
token.
