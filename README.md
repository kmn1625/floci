# floci

Local cloud labs on the [Floci](https://floci.io) emulators: build, deploy and test
real infrastructure code without a cloud account or a bill.

| Folder | Emulator | Port | Status |
|---|---|---|---|
| [`azure/`](azure/) | `floci/floci-az:0.15.0-compat` | 4577 (HTTP + HTTPS) | in progress |
| [`aws/`](aws/) | `floci/floci:1.5.15` | 4566 | test harness (pytest + Terraform override) |

## Quick start

```bash
docker compose -f azure/docker-compose.yml up -d
curl -sk https://localhost:4577/_floci/health      # {"status":"UP","version":"0.15.0",...}

docker compose -f aws/docker-compose.yml up -d
curl -s http://localhost:4566/_floci/health
```

Needs Docker Desktop (or any Docker engine). Both emulators start Docker-backed
services (Kubernetes, registries, databases) through the mounted Docker socket.

## Run the Azure lab

```bash
cd azure
docker compose up -d                                   # floci-az
docker compose --profile tools build toolbox           # pinned terraform/kubectl/helm/ansible
docker compose run --rm toolbox terraform -chdir=terraform init
docker compose run --rm toolbox terraform -chdir=terraform plan -out=tfplan
docker compose run --rm toolbox terraform -chdir=terraform apply tfplan
```

Everything runs in the toolbox container: it trusts the emulator's TLS certificate and
blocks every Azure domain from reaching the real cloud (see `azure/FINDINGS.md` F-01).
36+ resources converge; services the emulator cannot manage yet sit behind
`-var include_known_emulator_gaps=true`, each tied to a finding.

### App on AKS (from the emulated ACR)

```bash
docker build -t hello-api:0.1.1 --build-arg VERSION=0.1.1 apps/hello-api
docker tag hello-api:0.1.1 localhost:5001/<acr-name>/hello-api:0.1.1 && docker push localhost:5001/<acr-name>/hello-api:0.1.1
bash azure/scripts/aks-connect.sh <acr-name>          # kubeconfig + ACR mirror (F-16, F-26)
docker compose -f azure/docker-compose.yml run --rm -v "$PWD/k8s:/k8s:ro" toolbox   sh -c 'KUBECONFIG=/work/out/aks.kubeconfig kubectl apply -k /k8s/hello-api/overlays/aks'
```

`k8s/hello-api` ships a restricted-PSA namespace, a token-less service account, viewer and
deployer RBAC roles, default-deny NetworkPolicy, PDB and a digest-pinned image. Verified on
the emulated AKS: rollout healthy, cross-namespace traffic blocked, privileged pods rejected.

## Real Kubernetes on VMs (kubeadm + Argo CD)

Windows 11 Pro with Hyper-V and Multipass (`winget install Canonical.Multipass`):

```powershell
powershell -ExecutionPolicy Bypass -File vms/up.ps1
$env:KUBECONFIG = "vms/.keys/kubeconfig"; kubectl get nodes
kubectl -n argocd port-forward svc/argocd-server 8443:443        # https://localhost:8443, user admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'   # base64
```

3 Ubuntu 24.04 VMs; cloud-init installs containerd and kubeadm/kubelet/kubectl 1.36.6; Ansible (run on
the control plane) does `kubeadm init`, Calico v3.33.0, worker join and Argo CD v3.5.6. Argo CD's root app
syncs `k8s/argocd/apps` from this repo: `platform` (namespaces, cluster RBAC, quota, limits, default-deny)
and `hello-api` (image `ghcr.io/kmn1625/hello-api` by digest). Verified: all Synced/Healthy, NetworkPolicy
blocks other namespaces, RBAC roles behave, restricted PSA rejects privileged pods, deleted resources self-heal.
After a laptop restart the VMs start with Multipass; for the Azure emulator run `bash azure/scripts/recover-after-restart.sh`.

## Observability (on the kubeadm cluster)

Argo CD installs from pinned Helm charts (`k8s/argocd/apps/observability.yaml`): kube-prometheus-stack 92.16.1
(Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics), Loki 7.5.0, Tempo 1.24.4 and Grafana
Alloy 1.15.0 (pod logs through the Kubernetes API). `hello-api` 0.2.0 exposes `/metrics`, sends OpenTelemetry
traces to Tempo and writes JSON logs with `trace_id`, so Grafana jumps from a log line to its trace.

```powershell
kubectl -n observability port-forward svc/kps-grafana 3000:80     # http://localhost:3000, user admin
kubectl -n observability get secret kps-grafana -o jsonpath='{.data.admin-password}'   # base64
```

Verified 31 Oct 2026: every Prometheus target up (hello-api, kubelet, node-exporter, API server, CoreDNS...),
Grafana datasources Prometheus, Loki and Tempo healthy, app logs in Loki, a log's `trace_id` opens its trace in
Tempo. The stack needs 3 GB workers; on a 4-core laptop pause the Floci emulators while it runs.

## Azure services in floci-az 0.15.0

Verified from the running emulator's startup banner (2026-10-31). floci-az has no
web console; it is API-only (`/_floci/ui` returns 404). The AWS emulator's console
is at `http://localhost:4566/_floci/ui`.

| Real (Docker-backed) | Data stored by the emulator, no containers | Mocked by default |
|---|---|---|
| AKS (k3s), ACR (`registry:2`), Functions, PostgreSQL, MySQL, MariaDB, Redis (Valkey), Event Hubs (AMQP) | Blob, Queue, Table, Cosmos DB, Key Vault, App Configuration, SQL (management plane), VNet / subnet / NIC / public IP / NSG / DNS, Managed Identity, Entra ID (OIDC), Graph slice, ARM, Policy, API Management, Event Grid, Monitor / Log Analytics, SignalR, Email | VMs, ACI, Container Apps, Service Bus |

## Roadmap

1. **Azure lab** — one Terraform project touching every service above; app image built
   and pushed to the emulated ACR; deployed to AKS and to Container Apps / ACI.
2. **Real Kubernetes on VMs** — 3 Ubuntu VMs (Hyper-V + Multipass), cloud-init +
   Ansible + kubeadm (not k3s / minikube), namespaces and RBAC, Argo CD deploying
   this repo's manifests from GitHub.
3. **AWS lab** — the same on `floci` (EKS, ECR, VPC, IAM, RDS, ...).

## License

Apache-2.0. See [LICENSE](LICENSE).
