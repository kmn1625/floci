terraform {
  required_version = ">= 1.16.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.81.0" # floci-az documents 3.x/4.x; 5.x is tested separately
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}
