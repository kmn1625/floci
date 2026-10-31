output "storage_account" {
  value = azurerm_storage_account.lab.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.lab.vault_uri
}

output "acr_login_server" {
  value = azurerm_container_registry.lab.login_server
}

output "postgres_host" {
  value = azurerm_postgresql_flexible_server.lab.fqdn
}

output "redis" {
  value = {
    host = azurerm_redis_cache.lab.hostname
    port = azurerm_redis_cache.lab.port
    key  = azurerm_redis_cache.lab.primary_access_key
  }
  sensitive = true
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}
