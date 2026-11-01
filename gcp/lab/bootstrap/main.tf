# One-time bootstrap: the deployer service account the lab root impersonates.
#
# With IAM enforcement on, floci-gcp evaluates only Floci-issued service-account tokens;
# external tokens (GOOGLE_OAUTH_ACCESS_TOKEN) are treated as anonymous, and GCS then denies
# the creator its own bucket (FINDINGS G-09). On GCP the same split exists: a bootstrap
# identity creates the deployer, and pipelines impersonate it instead of holding a key.
terraform {
  required_version = ">= 1.16.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.9.0"
    }
  }
}

variable "floci_endpoint" {
  type    = string
  default = "http://floci-gcp:4588"
}

variable "project" {
  type    = string
  default = "flocilab"
}

provider "google" {
  project                          = var.project
  user_project_override            = false
  iam_custom_endpoint              = "${var.floci_endpoint}/"
  iam_beta_custom_endpoint         = "${var.floci_endpoint}/v1/" # service accounts
  resource_manager_custom_endpoint = "${var.floci_endpoint}/v1/"
}

resource "google_service_account" "deployer" {
  account_id   = "flocilab-deployer"
  display_name = "Terraform deployer for the lab root (impersonated, no keys)"
}

# Broad on purpose: the lab root creates resources in every service. A production deployer
# gets the narrower predefined roles for the services it manages.
resource "google_project_iam_member" "deployer_owner" {
  # devops:approved-privilege lab deployer creates resources in every service; production gets per-service roles
  project = var.project
  role    = "roles/owner"
  member  = google_service_account.deployer.member
}

output "deployer_email" {
  value = google_service_account.deployer.email
}
