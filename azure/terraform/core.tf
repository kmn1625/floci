data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = "rg-${var.prefix}-${var.environment}"
  location = var.location
  tags     = local.tags
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

# ── Identity ────────────────────────────────────────────────────────────────
resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-${var.prefix}-workload"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

# ── Monitoring ──────────────────────────────────────────────────────────────
# Create fails on floci-az: the provider first lists deleted workspaces, which the
# emulator does not implement (F-02). Re-test with -var include_known_emulator_gaps=true.
resource "azurerm_log_analytics_workspace" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0
  name                = "log-${var.prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}
