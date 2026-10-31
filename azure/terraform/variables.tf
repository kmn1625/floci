variable "floci_az_host" {
  description = "host:port serving /metadata/endpoints over HTTPS (floci-az on the compose network)"
  type        = string
  default     = "floci-az:4577"
}

variable "prefix" {
  description = "Short lowercase name prefix for every resource (letters and digits only)"
  type        = string
  default     = "flocilab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.prefix))
    error_message = "prefix must be 3-12 lowercase letters/digits, starting with a letter (storage/ACR/Key Vault naming rules)."
  }
}

variable "include_known_emulator_gaps" {
  description = "Also create resources that floci-az 0.15.0 cannot serve yet (see FINDINGS.md) to re-test them"
  type        = bool
  default     = false
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "environment" {
  type    = string
  default = "dev"
}

locals {
  tags = {
    Project     = "floci-lab"
    Environment = var.environment
    Owner       = "platform-team"
    ManagedBy   = "terraform"
  }
}
