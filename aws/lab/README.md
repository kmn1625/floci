# AWS lab on Floci 2.3.0

```bash
docker compose -f aws/lab/docker-compose.yml up -d                     # Floci, console http://localhost:4566/_floci/ui
docker compose -f aws/lab/docker-compose.yml --profile tools build toolbox
docker compose -f aws/lab/docker-compose.yml --profile tools run --rm toolbox terraform -chdir=terraform init
docker compose -f aws/lab/docker-compose.yml --profile tools run --rm toolbox terraform -chdir=terraform plan -out=tfplan
docker compose -f aws/lab/docker-compose.yml --profile tools run --rm toolbox terraform -chdir=terraform apply tfplan
```

The toolbox signs as Floci's seeded deployer (`floci`/`floci`) and resolves every `*.amazonaws.com`
name locally, so nothing can reach real AWS. 93 resources across 25 services converge; see
[FINDINGS.md](FINDINGS.md) for where Floci differs from AWS.

```bash
cd aws/lab
docker compose --profile tools run --rm toolbox sh -c "pip install -q boto3 && python3 tests/smoke.py"  # data planes + IAM
bash scripts/ecr-push.sh      # hello-api 0.2.0 from GHCR into the lab ECR (crane; Docker Desktop can't resolve *.localhost)
bash scripts/eks-deploy.sh    # k8s/hello-api/overlays/eks onto the lab EKS (k3s), image pulled from ECR by digest
```

`scripts/eks_kubeconfig.py` writes a kubeconfig that logs in the real EKS way (IAM token through an exec
plugin, nothing stored). Floci 2.3.0 rejects those tokens (FINDINGS A-19), so `eks-deploy.sh` uses the k3s
admin kubeconfig inside the cluster container instead.
