# floci-az findings

Behaviour found while driving `floci/floci-az:0.15.0-compat` with Terraform
(`hashicorp/azurerm` 4.81.0) from the toolbox container. Each entry: what happens, how it
was verified, and what the lab does about it. Re-test the gated ones with
`-var include_known_emulator_gaps=true`.

| ID | Area | Finding | Lab workaround |
|---|---|---|---|
| F-01 | DNS / data planes | ARM responses carry **real Azure hostnames**: `vaultUri https://<kv>.vault.azure.net/`, storage `primaryEndpoints http://<acct>.{blob,queue,table,dfs}.core.windows.net/`, ACR `loginServer <name>.azurecr.io`. Docker's DNS (and floci-az's embedded DNS) resolve these to **real Azure IPs** (`*.vault.azure.net` → 40.71.10.202), so clients leave the machine. Key Vault create hung on `GetCertificateContacts` against real Azure until it timed out. | Toolbox egress guard: dnsmasq resolves every Azure domain to 127.0.0.1 (IPv6 answers filtered), socat forwards :80/:443 to `floci-az:4577`. floci-az routes by Host header and its cert covers `*.vault.azure.net` / `*.azurecr.io`. |
| F-02 | Log Analytics | Create fails: the provider lists `Microsoft.OperationalInsights/deletedWorkspaces`, floci-az returns 404 `ResourceNotFound`. | Gated (`include_known_emulator_gaps`). |
| F-03 | Storage (ARM) | `GET .../blobServices/default/containers/<any name>` returns **200** for containers that do not exist, so `azurerm_storage_container` with `storage_account_id` always reports "already exists". | Use `storage_account_name` (data-plane path, correct 404) through the egress guard. |
| F-04 | Storage | `min_tls_version`, `https_traffic_only_enabled`, `allow_nested_items_to_be_public` are not persisted: the account reads back **TLS1_0, HTTP allowed, public nested items allowed**. Security settings silently weaker than the code. | `ignore_changes`; noted as a test-fidelity risk. |
| F-05 | Storage | `queue_encryption_key_type` / `table_encryption_key_type` read back `Account` (requested default `Service`); both are ForceNew → the account would be replaced on every plan. | `ignore_changes`. |
| F-06 | Key Vault | `soft_delete_retention_days` always reads back 90 (requested 7). | `ignore_changes`. |
| F-07 | ACR | `role_assignment_mode` not returned → perpetual in-place update. | `ignore_changes`. |
| F-08 | Table data plane | `GET /Tables('<any name>')` returns **200** `{"value":[]}` for tables that do not exist (should be 404), so `azurerm_storage_table` always reports "already exists". | Gated; table service exercised by smoke tests. |
| F-09 | Key Vault | Vault PUT drops `accessPolicies` and `tags` (read back empty). | `ignore_changes`. |
| F-10 | Storage | Account PATCH drops `tags`. | `ignore_changes`. |
| F-11 | Key Vault | Vault create takes ~2m11s (provider polls a status the emulator does not settle quickly). | None; noted. |
| F-12 | Web UI | `/_floci/ui` returns 404 on 0.15.0 (README Quick Start says a console exists; Non-Goals say API-only). | Use the API / this lab. |
| F-13 | AKS | Uses `rancher/k3s:latest` (unpinned) for clusters. | To pin via config when AKS is added. |
