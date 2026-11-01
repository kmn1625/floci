resource "azurerm_virtual_network" "lab" {
  name                = "vnet-${var.prefix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.40.0.0/16"]
  tags                = local.tags
}

locals {
  subnets = {
    aks  = "10.40.0.0/22"
    apps = "10.40.4.0/24"
    data = "10.40.5.0/24"
    vms  = "10.40.6.0/24"
    jobs = "10.40.7.0/24"
  }
}

resource "azurerm_subnet" "this" {
  for_each             = local.subnets
  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [each.value]
}

resource "azurerm_network_security_group" "vms" {
  name                = "nsg-${var.prefix}-vms"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags

  # Kubernetes API from inside the VNet only — never 0.0.0.0/0 (§N network egress/ingress).
  security_rule {
    name                       = "allow-k8s-api-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # Day-2 S1: HTTPS from inside the VNet (ingress controller on the VMs).
  security_rule {
    name                       = "allow-https-vnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

# Every subnet gets an NSG (CKV2_AZURE_31). aks/apps/data use Azure's default rules.
resource "azurerm_network_security_group" "default" {
  name                = "nsg-${var.prefix}-default"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "default" {
  for_each                  = toset(["aks", "apps", "data", "jobs"])
  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.default.id
}

resource "azurerm_subnet_network_security_group_association" "vms" {
  subnet_id                 = azurerm_subnet.this["vms"].id
  network_security_group_id = azurerm_network_security_group.vms.id
}

resource "azurerm_public_ip" "ingress" {
  name                = "pip-${var.prefix}-ingress"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "cp" {
  name                = "nic-${var.prefix}-cp"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.this["vms"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_private_dns_zone" "internal" {
  name                = "${var.prefix}.internal"
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "internal" {
  name                  = "link-${var.prefix}"
  resource_group_name   = azurerm_resource_group.lab.name
  private_dns_zone_name = azurerm_private_dns_zone.internal.name
  virtual_network_id    = azurerm_virtual_network.lab.id
  tags                  = local.tags
}
