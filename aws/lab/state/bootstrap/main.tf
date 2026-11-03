# State backend for the state-recovery tests: versioned, encrypted S3 bucket + DynamoDB lock
# table (the layout devops-project's backend-<env>.hcl documents). Local state on purpose:
# this is the thing that holds everyone else's state.
terraform {
  required_version = "~> 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.58" }
  }
}

variable "floci_endpoint" {
  type    = string
  default = "http://floci-lab:4566"
}

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true
  endpoints {
    dynamodb = var.floci_endpoint
    s3       = var.floci_endpoint
    sts      = var.floci_endpoint
  }
}

resource "aws_s3_bucket" "state" {
  bucket = "flocilab-tfstate"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = "flocilab-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
