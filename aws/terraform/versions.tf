# versions.tf — Terraform version constraints for Floci agent test suite.
# All test phases inherit this via symlink or copy.
# Minimum Terraform: 1.10+ (Floci compatibility requirement — RESEARCH.md)
# AWS Provider: v6.x tested baseline; v5 also works but v6 is standard.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
