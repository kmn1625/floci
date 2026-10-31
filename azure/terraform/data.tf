# ── Cosmos DB (NoSQL) ───────────────────────────────────────────────────────
resource "azurerm_cosmosdb_account" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "cosmos-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  minimal_tls_version = "Tls12"
  tags                = local.tags

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.lab.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "app" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "app"
  resource_group_name = azurerm_resource_group.lab.name
  account_name        = azurerm_cosmosdb_account.lab[0].name
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "orders"
  resource_group_name = azurerm_resource_group.lab.name
  account_name        = azurerm_cosmosdb_account.lab[0].name
  database_name       = azurerm_cosmosdb_sql_database.app[0].name
  partition_key_paths = ["/customerId"]
}

# ── PostgreSQL / MySQL flexible servers (real containers on floci-az) ───────
resource "azurerm_postgresql_flexible_server" "lab" {
  name                          = "psql-${var.prefix}-${random_string.suffix.result}"
  location                      = azurerm_resource_group.lab.location
  resource_group_name           = azurerm_resource_group.lab.name
  version                       = "16"
  sku_name                      = "B_Standard_B1ms"
  storage_mb                    = 32768
  administrator_login           = "labadmin"
  administrator_password        = random_password.db.result
  public_network_access_enabled = true
  tags                          = local.tags

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "vnet_only" {
  name             = "vnet-only"
  server_id        = azurerm_postgresql_flexible_server.lab.id
  start_ip_address = "10.40.0.0"
  end_ip_address   = "10.40.255.255"
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = "app"
  server_id = azurerm_postgresql_flexible_server.lab.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_mysql_flexible_server" "lab" {
  count                  = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                   = "mysql-${var.prefix}-${random_string.suffix.result}"
  location               = azurerm_resource_group.lab.location
  resource_group_name    = azurerm_resource_group.lab.name
  version                = "8.0.21"
  sku_name               = "B_Standard_B1ms"
  administrator_login    = "labadmin"
  administrator_password = random_password.db.result
  tags                   = local.tags

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_mysql_flexible_database" "app" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "app"
  resource_group_name = azurerm_resource_group.lab.name
  server_name         = azurerm_mysql_flexible_server.lab[0].name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# ── Azure SQL (management plane on floci-az) ────────────────────────────────
resource "azurerm_mssql_server" "lab" {
  #checkov:skip=CKV_AZURE_24:Gated resource (F-18); auditing needs a storage/Log Analytics sink
  count                        = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md F-18
  name                         = "sql-${var.prefix}-${random_string.suffix.result}"
  location                     = azurerm_resource_group.lab.location
  resource_group_name          = azurerm_resource_group.lab.name
  version                      = "12.0"
  administrator_login          = "labadmin"
  administrator_login_password = random_password.db.result
  minimum_tls_version          = "1.2"
  tags                         = local.tags
}

resource "azurerm_mssql_database" "app" {
  count     = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md F-18
  name      = "app"
  server_id = azurerm_mssql_server.lab[0].id
  sku_name  = "Basic"
  tags      = local.tags
}

# ── Redis (Valkey container on floci-az) ────────────────────────────────────
resource "azurerm_redis_cache" "lab" {
  name                 = "redis-${var.prefix}-${random_string.suffix.result}"
  location             = azurerm_resource_group.lab.location
  resource_group_name  = azurerm_resource_group.lab.name
  capacity             = 0
  family               = "C"
  sku_name             = "Basic"
  minimum_tls_version  = "1.2"
  non_ssl_port_enabled = false
  tags                 = local.tags

  lifecycle {
    ignore_changes = [redis_version] # floci-az (Valkey 8) reports "7.0" (F-20)
  }
}
