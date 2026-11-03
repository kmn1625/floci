# The layout devops-project's backend-<env>.hcl uses today: DynamoDB lock table.
bucket         = "flocilab-tfstate"
key            = "state-lab/terraform.tfstate"
region         = "us-east-1"
encrypt        = true
dynamodb_table = "flocilab-tfstate-lock"
use_path_style = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_region_validation      = true
skip_metadata_api_check     = true
endpoints = {
  s3       = "http://floci-lab:4566"
  dynamodb = "http://floci-lab:4566"
  sts      = "http://floci-lab:4566"
}
