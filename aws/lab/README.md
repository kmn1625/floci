# AWS lab on Floci 2.3.0

```bash
docker compose -f aws/lab/docker-compose.yml up -d                     # Floci, console http://localhost:4566/_floci/ui
docker compose -f aws/lab/docker-compose.yml --profile tools build toolbox
docker compose -f aws/lab/docker-compose.yml --profile tools run --rm toolbox terraform -chdir=terraform init
docker compose -f aws/lab/docker-compose.yml --profile tools run --rm toolbox terraform -chdir=terraform plan -out=tfplan
docker compose -f aws/lab/docker-compose.yml --profile tools run --rm toolbox terraform -chdir=terraform apply tfplan
```

The toolbox signs as Floci's seeded deployer (`floci`/`floci`) and resolves every `*.amazonaws.com`
name locally, so nothing can reach real AWS. 92 resources across 25 services converge; see
[FINDINGS.md](FINDINGS.md) for where Floci differs from AWS.
