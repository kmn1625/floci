# Every service the lab uses points at Floci; anything missed resolves to 127.0.0.1 in the
# toolbox (egress guard) and fails instead of reaching real AWS. Credentials come from the
# environment (AWS_ACCESS_KEY_ID = Floci's seeded deployer principal), never from HCL.
provider "aws" {
  region                      = var.region
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true

  default_tags {
    tags = local.tags
  }

  endpoints {
    acm            = var.floci_endpoint
    apigatewayv2   = var.floci_endpoint
    backup         = var.floci_endpoint
    cloudwatch     = var.floci_endpoint
    cognitoidp     = var.floci_endpoint
    dynamodb       = var.floci_endpoint
    ec2            = var.floci_endpoint
    ecr            = var.floci_endpoint
    ecs            = var.floci_endpoint
    eks            = var.floci_endpoint
    elasticache    = var.floci_endpoint
    elbv2          = var.floci_endpoint
    events         = var.floci_endpoint
    iam            = var.floci_endpoint
    kinesis        = var.floci_endpoint
    kms            = var.floci_endpoint
    lambda         = var.floci_endpoint
    logs           = var.floci_endpoint
    rds            = var.floci_endpoint
    route53        = var.floci_endpoint
    s3             = var.floci_endpoint
    scheduler      = var.floci_endpoint
    secretsmanager = var.floci_endpoint
    sfn            = var.floci_endpoint
    sns            = var.floci_endpoint
    sqs            = var.floci_endpoint
    ssm            = var.floci_endpoint
    sts            = var.floci_endpoint
  }
}
