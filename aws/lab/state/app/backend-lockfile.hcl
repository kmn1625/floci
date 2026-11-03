# Terraform >= 1.10 native S3 locking: a .tflock object next to the state, no DynamoDB.
bucket         = "flocilab-tfstate"
key            = "state-lab/terraform.tfstate"
region         = "us-east-1"
encrypt        = true
use_lockfile   = true
use_path_style = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_region_validation      = true
skip_metadata_api_check     = true
endpoints = {
  s3  = "http://floci-lab:4566"
  sts = "http://floci-lab:4566"
}
