# ── App Configuration ───────────────────────────────────────────────────────
resource "azurerm_app_configuration" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "appcs-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "free"
  tags                = local.tags
}

# ── Container Apps ──────────────────────────────────────────────────────────
resource "azurerm_container_app_environment" "lab" {
  name                = "cae-${var.prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_container_app" "web" {
  name                         = "ca-${var.prefix}-web"
  container_app_environment_id = azurerm_container_app_environment.lab.id
  resource_group_name          = azurerm_resource_group.lab.name
  revision_mode                = "Single"
  tags                         = local.tags

  template {
    container {
      name   = "web"
      image  = "nginxinc/nginx-unprivileged:1.27-alpine"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# ── Container Instances (ACI) ───────────────────────────────────────────────
resource "azurerm_container_group" "job" {
  name                = "aci-${var.prefix}-job"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  os_type             = "Linux"
  ip_address_type     = "None"
  restart_policy      = "OnFailure"
  tags                = local.tags

  container {
    name     = "job"
    image    = "busybox:1.37"
    cpu      = 0.5
    memory   = 0.5
    commands = ["sh", "-c", "echo floci-lab job ran && sleep 5"]
  }
}

# ── Functions (Linux, consumption) ──────────────────────────────────────────
resource "azurerm_service_plan" "func" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "asp-${var.prefix}-func"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = local.tags
}

resource "azurerm_linux_function_app" "api" {
  count                      = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                       = "func-${var.prefix}-${random_string.suffix.result}"
  location                   = azurerm_resource_group.lab.location
  resource_group_name        = azurerm_resource_group.lab.name
  service_plan_id            = azurerm_service_plan.func[0].id
  storage_account_name       = azurerm_storage_account.lab.name
  storage_account_access_key = azurerm_storage_account.lab.primary_access_key
  https_only                 = true
  tags                       = local.tags

  site_config {
    minimum_tls_version = "1.2"
    application_stack {
      python_version = "3.12"
    }
  }
}

# ── SignalR ─────────────────────────────────────────────────────────────────
resource "azurerm_signalr_service" "lab" {
  count               = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md
  name                = "sigr-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags

  sku {
    name     = "Free_F1"
    capacity = 1
  }
}

# ── API Management ──────────────────────────────────────────────────────────
resource "azurerm_api_management" "lab" {
  name                = "apim-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  publisher_name      = "floci-lab"
  publisher_email     = "platform@example.com"
  sku_name            = "Consumption_0"
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags] # create drops tags and PATCH returns 405 (F-15)
  }
}

# ── Virtual machine (mocked by floci-az; real VMs come from ../vms) ─────────
resource "tls_private_key" "vm" {
  algorithm = "ED25519"
}

resource "azurerm_linux_virtual_machine" "cp" {
  name                  = "vm-${var.prefix}-cp"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  size                  = "Standard_B2s"
  admin_username        = "labadmin"
  network_interface_ids = [azurerm_network_interface.cp.id]
  tags                  = local.tags

  admin_ssh_key {
    username   = "labadmin"
    public_key = tls_private_key.vm.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    ignore_changes = [tags, additional_capabilities] # mocked VM drops both (F-21)
  }
}
