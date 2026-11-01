# Day-2 T1: resources first created by hand (portal), brought under Terraform.

# office-vpn was adopted with an import block (terraform plan -generate-config-out, then reviewed);
# the block was removed after the apply, as import blocks are one-shot.
resource "azurerm_postgresql_flexible_server_firewall_rule" "office_vpn" {
  name             = "office-vpn"
  server_id        = azurerm_postgresql_flexible_server.lab.id
  start_ip_address = "10.50.0.0"
  end_ip_address   = "10.50.255.255"
}

# T3: office-vpn (removed block) and snet-jobs (terraform state rm) were forgotten, still existed in
# Azure, and were re-adopted with import blocks, removed again after the apply.

# nsg-flocilab-manual (T1, CLI import) was deleted by hand in T2b and retired from the code.
