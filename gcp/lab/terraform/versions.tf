terraform {
  required_version = ">= 1.16.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.9.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.8.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}
