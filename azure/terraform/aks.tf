# AKS on floci-az runs a real k3s container per cluster (API on 6443-7443).
# The production-style cluster is kubeadm on VMs (../vms); this one exercises the AKS API.
resource "azurerm_kubernetes_cluster" "lab" {
  count                             = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md F-16/F-17 (AKS via scripts/aks.sh)
  name                              = "aks-${var.prefix}"
  location                          = azurerm_resource_group.lab.location
  resource_group_name               = azurerm_resource_group.lab.name
  dns_prefix                        = "${var.prefix}aks"
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  tags                              = local.tags

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_B2s"
    vnet_subnet_id = azurerm_subnet.this["aks"].id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.41.0.0/16"
    dns_service_ip = "10.41.0.10"
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  count                 = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md F-16/F-17 (AKS via scripts/aks.sh)
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.lab[0].id
  vm_size               = "Standard_B2s"
  node_count            = 1
  vnet_subnet_id        = azurerm_subnet.this["aks"].id
  tags                  = local.tags
}

# AKS kubelet identity may pull from ACR (RBAC on the registry scope).
resource "azurerm_role_assignment" "aks_acr_pull" {
  count                = var.include_known_emulator_gaps ? 1 : 0 # FINDINGS.md F-16/F-17 (AKS via scripts/aks.sh)
  scope                = azurerm_container_registry.lab.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.lab[0].kubelet_identity[0].object_id
}
