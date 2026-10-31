# ── Storage (blob, queue, table) ────────────────────────────────────────────
resource "azurerm_storage_account" "lab" {
  #checkov:skip=CKV2_AZURE_1:Emulator lab; customer-managed keys need a CMK + identity wiring floci-az does not model
  name                            = "st${var.prefix}${random_string.suffix.result}"
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  lifecycle {
    # floci-az 0.15.0 does not persist these (FINDINGS.md F-04/F-05): it reports
    # TLS1_0 / HTTP allowed / public nested items and "Account" encryption keys,
    # which would replace the account on every plan. Remove on real Azure.
    ignore_changes = [
      min_tls_version, https_traffic_only_enabled, allow_nested_items_to_be_public,
      queue_encryption_key_type, table_encryption_key_type,
      tags, # PATCH drops tags (F-10)
    ]
  }
}

# storage_account_name = data-plane API (via the toolbox egress guard). The ARM path
# (storage_account_id) fails: floci-az answers 200 for a container that does not exist (F-03).
resource "azurerm_storage_container" "artifacts" {
  #checkov:skip=CKV2_AZURE_21:Blob read logging needs Log Analytics, which floci-az cannot create (F-02)
  name                  = "artifacts"
  storage_account_name  = azurerm_storage_account.lab.name
  container_access_type = "private"
}

resource "azurerm_storage_queue" "jobs" {
  name                 = "jobs"
  storage_account_name = azurerm_storage_account.lab.name
}

# floci-az answers 200 for GET Tables('<any name>') (F-08), so the provider's
# "already exists" check always fails. The table data plane is covered by smoke tests.
resource "azurerm_storage_table" "audit" {
  count                = var.include_known_emulator_gaps ? 1 : 0
  name                 = "audit"
  storage_account_name = azurerm_storage_account.lab.name
}

# ── Key Vault (secret + key) ────────────────────────────────────────────────
resource "azurerm_key_vault" "lab" {
  name                       = "kv-${var.prefix}-${random_string.suffix.result}"
  location                   = azurerm_resource_group.lab.location
  resource_group_name        = azurerm_resource_group.lab.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags

  access_policy {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    object_id          = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
    key_permissions    = ["Get", "List", "Create", "Delete", "Purge", "GetRotationPolicy"]
  }

  lifecycle {
    # floci-az reports retention 90 (F-06) and drops access policies + tags (F-09)
    ignore_changes = [soft_delete_retention_days, access_policy, tags]
  }
}

resource "random_password" "db" {
  length  = 24
  special = true
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.lab.id
  content_type = "password"
  tags         = local.tags
}

resource "azurerm_key_vault_key" "app" {
  name         = "app-signing"
  key_vault_id = azurerm_key_vault.lab.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["sign", "verify"]
  tags         = local.tags
}

# ── Container registry ──────────────────────────────────────────────────────
resource "azurerm_container_registry" "lab" {
  name                = "acr${var.prefix}${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Basic"
  admin_enabled       = true # floci-az ACR login flow uses admin credentials
  tags                = local.tags

  lifecycle {
    ignore_changes = [role_assignment_mode] # not returned by floci-az (F-07)
  }
}
