# ── Policy: every resource in the lab RG must carry an Owner tag ────────────
resource "azurerm_policy_definition" "require_owner_tag" {
  name         = "${var.prefix}-require-owner-tag"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require an Owner tag"

  policy_rule = jsonencode({
    if   = { field = "tags['Owner']", exists = "false" }
    then = { effect = "deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "require_owner_tag" {
  name                 = "require-owner-tag"
  resource_group_id    = azurerm_resource_group.lab.id
  policy_definition_id = azurerm_policy_definition.require_owner_tag.id
}

# ── RBAC: workload identity may read Key Vault secrets ──────────────────────
resource "azurerm_role_assignment" "workload_kv_secrets" {
  count                = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md F-17/F-19
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

# ── Monitor: action group for alerts ────────────────────────────────────────
resource "azurerm_monitor_action_group" "oncall" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "ag-${var.prefix}-oncall"
  resource_group_name = azurerm_resource_group.lab.name
  short_name          = "oncall"
  tags                = local.tags

  email_receiver {
    name          = "platform"
    email_address = "platform@example.com"
  }
}

# ── Communication Services + Email ──────────────────────────────────────────
resource "azurerm_email_communication_service" "lab" {
  name                = "ecs-${var.prefix}"
  resource_group_name = azurerm_resource_group.lab.name
  data_location       = "United States"
  tags                = local.tags
}

resource "azurerm_communication_service" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md F-17/F-19
  name                = "acs-${var.prefix}"
  resource_group_name = azurerm_resource_group.lab.name
  data_location       = "United States"
  tags                = local.tags
}
