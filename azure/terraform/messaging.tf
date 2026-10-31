# ── Service Bus ─────────────────────────────────────────────────────────────
resource "azurerm_servicebus_namespace" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "sb-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  minimum_tls_version = "1.2"
  tags                = local.tags
}

resource "azurerm_servicebus_queue" "orders" {
  count        = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name         = "orders"
  namespace_id = azurerm_servicebus_namespace.lab[0].id
}

resource "azurerm_servicebus_topic" "events" {
  count        = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name         = "events"
  namespace_id = azurerm_servicebus_namespace.lab[0].id
}

resource "azurerm_servicebus_subscription" "audit" {
  count              = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name               = "audit"
  topic_id           = azurerm_servicebus_topic.events[0].id
  max_delivery_count = 10
}

# ── Event Hubs ──────────────────────────────────────────────────────────────
resource "azurerm_eventhub_namespace" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "evh-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  capacity            = 1
  minimum_tls_version = "1.2"
  tags                = local.tags
}

resource "azurerm_eventhub" "telemetry" {
  count             = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name              = "telemetry"
  namespace_id      = azurerm_eventhub_namespace.lab[0].id
  partition_count   = 2
  message_retention = 1
}

resource "azurerm_eventhub_consumer_group" "analytics" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "analytics"
  namespace_name      = azurerm_eventhub_namespace.lab[0].name
  eventhub_name       = azurerm_eventhub.telemetry[0].name
  resource_group_name = azurerm_resource_group.lab.name
}

# ── Event Grid ──────────────────────────────────────────────────────────────
resource "azurerm_eventgrid_topic" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "evgt-${var.prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}
