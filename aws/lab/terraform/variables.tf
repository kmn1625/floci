variable "floci_endpoint" {
  description = "Floci on the compose network"
  type        = string
  default     = "http://floci-lab:4566"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "prefix" {
  description = "Short lowercase name prefix (S3/ECR naming rules)"
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

variable "include_known_emulator_gaps" {
  description = "Also create resources Floci cannot serve yet (see ../FINDINGS.md) to re-test them"
  type        = bool
  default     = false
}

locals {
  tags = {
    Project     = "floci-lab"
    Environment = var.environment
    Owner       = "platform-team"
    ManagedBy   = "terraform"
  }
  azs = ["${var.region}a", "${var.region}b"]
}

data "aws_caller_identity" "current" {}
