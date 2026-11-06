# Target for the on-prem to AWS drill: a database, a bucket for the uploads, a cluster for the app.
# Everything points at Floci. Credentials come from the toolbox environment, never from HCL.
terraform {
  required_version = ">= 1.16.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.71.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}

variable "floci_endpoint" {
  type    = string
  default = "http://floci-lab:4566"
}

locals {
  name = "shop"
  tags = { project = "migration-drill", owner = "lab", env = "drill" }
}

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true
  default_tags { tags = local.tags }
  endpoints {
    ec2            = var.floci_endpoint
    eks            = var.floci_endpoint
    iam            = var.floci_endpoint
    kms            = var.floci_endpoint
    rds            = var.floci_endpoint
    s3             = var.floci_endpoint
    secretsmanager = var.floci_endpoint
    sts            = var.floci_endpoint
  }
}

resource "aws_vpc" "shop" {
  cidr_block           = "10.60.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.shop.id
  cidr_block        = cidrsubnet(aws_vpc.shop.cidr_block, 8, count.index)
  availability_zone = "us-east-1${["a", "b"][count.index]}"
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "PostgreSQL for the app and the replication link"
  vpc_id      = aws_vpc.shop.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_vpc" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from inside the VPC"
  cidr_ipv4         = aws_vpc.shop.cidr_block
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({ username = "shopadmin", password = random_password.db.result })
}

resource "aws_db_subnet_group" "shop" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.private[*].id
}

# On real RDS the way back (the target publishing to the old server) needs this parameter.
resource "aws_db_parameter_group" "shop" {
  name   = "${local.name}-pg16"
  family = "postgres16"
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "shop" {
  identifier             = "${local.name}-pg"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  db_name                = "shop"
  username               = "shopadmin"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.shop.name
  parameter_group_name   = aws_db_parameter_group.shop.name
  vpc_security_group_ids = [aws_security_group.db.id]
  storage_encrypted      = true
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false
}

resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name}-uploads"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks" {
  name               = "${local.name}-eks"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks" {
  role       = aws_iam_role.eks.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "shop" {
  name     = local.name
  role_arn = aws_iam_role.eks.arn
  version  = "1.34"
  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = false
  }
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  depends_on = [aws_iam_role_policy_attachment.eks]
}

output "db_address" {
  value = aws_db_instance.shop.address
}

output "db_port" {
  value = aws_db_instance.shop.port
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

output "bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "cluster" {
  value = aws_eks_cluster.shop.name
}
