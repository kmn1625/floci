variable "floci_endpoint" {
  description = "floci-gcp on the compose network"
  type        = string
  default     = "http://floci-gcp:4588"
}

variable "project" {
  description = "floci-gcp default project (FLOCI_GCP_DEFAULT_PROJECT_ID); strict mode rejects others"
  type        = string
  default     = "flocilab"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "prefix" {
  description = "Short lowercase name prefix (bucket and service-account naming rules)"
  type        = string
  default     = "flocilab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.prefix))
    error_message = "prefix must be 3-16 lowercase letters, digits or dashes, starting with a letter."
  }
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "hello_api_image" {
  description = "hello-api 0.2.0 by digest. floci-gcp has no Artifact Registry (FINDINGS G-01), so it is pulled from GHCR."
  type        = string
  default     = "ghcr.io/kmn1625/hello-api@sha256:06a03e3721de009766ee788296f23c7438547f73406f8f852eacf1bf8aa279f9"
}

variable "include_known_emulator_gaps" {
  description = "Also create resources floci-gcp cannot serve yet (see ../FINDINGS.md) to re-test them"
  type        = bool
  default     = false
}

locals {
  labels = {
    project     = "floci-lab"
    environment = var.environment
    owner       = "platform-team"
    managed_by  = "terraform"
  }
  zone = "${var.region}-a"
}

data "google_project" "lab" {}
