# Target for the AWS to Azure drill: a database, a blob container for the uploads, a vault for the secret.
# Everything points at floci-az. The cluster is created by aks-up.sh: azurerm cannot read it back (azure/FINDINGS.md F-16).
terraform {
  required_version = ">= 1.16.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.81.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}

variable "floci_az_host" {
  type    = string
  default = "floci-az:4577"
}

locals {
  name = "shop"
  tags = { project = "migration-drill", owner = "lab", env = "drill" }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  use_cli         = false
  environment     = "stack"
  metadata_host   = var.floci_az_host
  subscription_id = "00000000-0000-0000-0000-000000000001"
  tenant_id       = "00000000-0000-0000-0000-000000000002"
  client_id       = "00000000-0000-0000-0000-000000000003"
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "shop" {
  name     = "rg-${local.name}-target"
  location = "eastus"
  tags     = local.tags
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "random_password" "db" {
  length  = 32
  special = false
}

# Where the bucket's objects go. Blob has no bucket policy, versioning flag or path-style key: see the README.
resource "azurerm_storage_account" "shop" {
  name                            = "st${local.name}${random_string.suffix.result}"
  location                        = azurerm_resource_group.shop.location
  resource_group_name             = azurerm_resource_group.shop.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
  lifecycle {
    ignore_changes = [ # devops:approved-ignore floci-az does not persist these (F-04/F-05/F-10)
      min_tls_version, https_traffic_only_enabled, allow_nested_items_to_be_public,
      queue_encryption_key_type, table_encryption_key_type, tags,
    ]
  }
}

resource "azurerm_storage_container" "uploads" {
  name                  = "uploads"
  storage_account_name  = azurerm_storage_account.shop.name
  container_access_type = "private"
}

# `version` is ignored by floci-az, which runs 17 (F-29). That makes this a major upgrade as well as a move.
resource "azurerm_postgresql_flexible_server" "shop" {
  name                   = "psql-${local.name}-${random_string.suffix.result}"
  location               = azurerm_resource_group.shop.location
  resource_group_name    = azurerm_resource_group.shop.name
  version                = "16"
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  administrator_login    = "shopadmin"
  administrator_password = random_password.db.result
  # devops:approved-exposure lab only: floci-az publishes it on the host anyway (F-30)
  public_network_access_enabled = true
  tags                          = local.tags
  lifecycle {
    ignore_changes = [zone]
  }
}

# Logical replication back to AWS needs this on the target, as rds.logical_replication does on RDS.
resource "azurerm_postgresql_flexible_server_configuration" "wal_level" {
  name      = "wal_level"
  server_id = azurerm_postgresql_flexible_server.shop.id
  value     = "logical"
}

resource "azurerm_key_vault" "shop" {
  name                       = "kv-${local.name}-${random_string.suffix.result}"
  location                   = azurerm_resource_group.shop.location
  resource_group_name        = azurerm_resource_group.shop.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  access_policy {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    object_id          = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "Set", "List", "Delete", "Purge"]
  }
  tags = local.tags
}

resource "azurerm_key_vault_secret" "db" {
  name         = "shop-db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.shop.id
  content_type = "text/plain"
}

output "storage_account" { value = azurerm_storage_account.shop.name }
output "storage_key" {
  value     = azurerm_storage_account.shop.primary_access_key
  sensitive = true
}
output "postgres_name" { value = azurerm_postgresql_flexible_server.shop.name }
output "postgres_host" { value = azurerm_postgresql_flexible_server.shop.fqdn }
output "postgres_password" {
  value     = random_password.db.result
  sensitive = true
}
output "key_vault_uri" { value = azurerm_key_vault.shop.vault_uri }
