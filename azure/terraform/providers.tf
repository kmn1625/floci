# floci-az: a custom ("stack") cloud discovered from https://<metadata_host>/metadata/endpoints.
# Credentials are not validated by the emulator; these are its fixed IDs.
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  use_cli       = false
  environment   = "stack"
  metadata_host = var.floci_az_host

  subscription_id = "00000000-0000-0000-0000-000000000001"
  tenant_id       = "00000000-0000-0000-0000-000000000002"
  client_id       = "00000000-0000-0000-0000-000000000003"
  # client_secret comes from ARM_CLIENT_SECRET (set on the toolbox service) —
  # never a literal in HCL, even for an emulator that does not validate it.
}
