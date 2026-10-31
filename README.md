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
