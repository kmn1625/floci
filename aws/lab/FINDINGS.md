# Floci (AWS) findings

Behaviour found while driving `floci/floci:2.3.0` with Terraform (`hashicorp/aws` 6.71.0) and
boto3 from the toolbox container (`CLOUD=aws`). Each entry: what happens, how it was verified,
and what the lab does about it. Re-test gated resources with `-var include_known_emulator_gaps=true`.

| ID | Area | Finding | Lab workaround |
|---|---|---|---|
| A-01 | Auth / upgrade | Floci 2.x seeds a different deployer: access key **`floci`** / secret `floci` (user `floci-deployer`, from the startup log). The 1.x key `fake-agent-key-001` — hard-coded in `aws/conftest.py` — is now rejected (`InvalidClientTokenId`), so the 1.x pytest harness breaks on upgrade. | Lab toolbox signs as `floci`/`floci`. |
| A-02 | Auth / security | With `FLOCI_SERVICES_IAM_ENFORCEMENT_ENABLED` and `FLOCI_AUTH_VALIDATE_SIGNATURES` on, the well-known default **`test`/`test` is accepted as the account root** (`arn:aws:iam::000000000000:root`). Any client that never set credentials gets root, so IAM policy enforcement cannot be tested against default-credential callers. | Lab never uses `test`; probe in `tests/probe_identity.py`. |
| A-03 | Web UI | Console at `http://localhost:4566/_floci/ui` answers (200); 127 services listed in `/_floci/health` (1.5.15 had 46). | — |
| A-04 | EC2 | The instance does not keep its `launch_template`, and the **root volume reads back unencrypted** although Terraform requested KMS encryption — a test would see weaker security than the code asks for; both would replace the instance on every plan. | `ignore_changes = [launch_template, root_block_device]`. |
| A-05 | ElastiCache | Replication group drops `security_group_ids`. | `ignore_changes`. |
| A-06 | Tags | Backup plan and EC2 key pair drop their tags (`default_tags`). | `ignore_changes = [tags, tags_all]`. |
| A-07 | S3 Control | Provider 6.x reads bucket tags through S3 Control, which prefixes the account to the host (`000000000000.floci-lab`). Not a Floci bug, but labs need `*.<floci host>` to resolve to the emulator. | Toolbox guard maps `*.floci-lab` to Floci. |

## Coverage (Terraform, aws 6.71.0, Floci 2.3.0)

All 92 resources converge with **no gated resources**: VPC, 4 subnets, IGW, route tables + associations, S3 gateway endpoint, 3 tiered security groups + rules, private Route 53 zone + alias record; KMS key + alias; IAM roles/policies (Lambda, Scheduler, Step Functions, EKS cluster + nodes); Secrets Manager secret + version; SSM String + SecureString; Cognito user pool + client; S3 bucket + versioning + KMS encryption + public access block + lifecycle; DynamoDB (PITR, KMS); RDS PostgreSQL 16 + subnet group; ElastiCache Valkey replication group (TLS, at-rest encryption); Backup vault + plan; SQS + DLQ + queue policy; SNS + SQS subscription; EventBridge rule + target; EventBridge Scheduler; Kinesis (KMS, on-demand); Step Functions state machine; Lambda (python3.12, X-Ray, KMS) + HTTP API + integration + route + stage + access logs + permission; CloudWatch log groups + alarm; ECR (immutable, scan on push, KMS) + lifecycle; EKS 1.34 (KMS secrets, private endpoint) + node group; ECS cluster + Fargate task definition; ACM (imported self-signed) + ALB (HTTPS, TLS 1.3 policy) + target group + listener; EC2 key pair + launch template (IMDSv2) + instance.
