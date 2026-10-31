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
| F-14 | ARM (generic) | `PUT` returns **404 ResourceNotFound** for every provider without a dedicated handler, even ones the startup banner lists as enabled: `Microsoft.AppConfiguration`, `Microsoft.ServiceBus`, `Microsoft.EventHub`, `Microsoft.DocumentDB` (Cosmos), `Microsoft.SignalRService`, `Microsoft.Web/serverFarms`, `Microsoft.Insights/actionGroups` (also `Microsoft.Contoso/widgets`). Their data planes exist; their management planes do not. | Gated. |
| F-15 | API Management | Create works but drops `tags`; any update (`PATCH`) returns **405 Method Not Allowed**. | `ignore_changes = [tags]`. |
| F-16 | AKS | GET has no `sku` → azurerm cannot read or import the cluster ("SKU information is missing"). `provisioningState` stays `Creating` forever, so `listClusterUserCredential` refuses (`OperationNotAllowed`, "no kubeconfig yet") although the k3s API is Ready. Requested pool name ignored (`nodepool1`). Reports Kubernetes 1.29; the container actually runs **k3s v1.34.1** from unpinned `rancher/k3s:latest`. | Gated in Terraform; `scripts/aks-connect.sh` reads the kubeconfig from the k3s container and wires the ACR mirror. |
| F-17 | RBAC | `GET roleDefinitions` returns no `value`; `PUT .../providers/Microsoft.Authorization/roleAssignments/<id>` under a resource scope returns 404 ("Unknown ACR path"). Built-in roles such as `Key Vault Secrets User`, `AcrPull` cannot be resolved. | Gated. |
| F-18 | Azure SQL | Server create works, but every read lists `restorableDroppedDatabases`, which is not implemented → server cannot be managed or imported. | Gated. |
| F-19 | Communication Services | Create works; read calls `listKeys`, not implemented. (Email Communication Service works.) | Gated. |
| F-20 | Redis | Reports `redisVersion 7.0` (Valkey 8 backend); provider default is `6` → perpetual update. | `ignore_changes`. |
| F-21 | Virtual machines (mocked) | Drops `tags` and `additional_capabilities`. | `ignore_changes`. |
| F-22 | MySQL flexible server | Response lacks `properties.storage` → **azurerm 4.81.0 panics** (nil pointer in `flattenArmServerStorage`, `mysql_flexible_server_resource.go:1028`). Provider bug (missing nil check) triggered by an incomplete emulator response; the crash aborts every in-flight create and leaves orphans in the emulator. The MySQL container does start. | Gated. Report upstream to both projects. |
| F-23 | Event Grid | Topic create returns 200; the provider expects 201 → create fails. | Gated. |
| F-25 | Key Vault | Secret update (`PATCH .../secrets/<name>/<version>`, e.g. adding tags) returns **405** with an empty body. Create with tags works. | Recreate (`-replace`) when secret metadata changes. |
| F-26 | ACR | The registry is **anonymous**: push and pull work without credentials, both on the published port and through `<acr>.azurecr.io`; admin credentials from `listCredentials` are never checked. Every ACR shares one `registry:2`, images stored under an `<acr-name>/` prefix. | Push to `localhost:<port>/<acr>/<repo>`; AKS pulls `<acr>.azurecr.io/<repo>` via a k3s mirror with a rewrite. |
| F-27 | Redis | `non_ssl_port_enabled = false` (ARM reports `enableNonSslPort: false`, `sslPort 6380`), but the Valkey container serves **plaintext on 6379** and nothing on 6380. | Smoke test reports it as a GAP. |
| F-28 | PostgreSQL | `azurerm_postgresql_flexible_server_database` succeeds, but the database exists **only in ARM** — the real Postgres container has no `app` database (`FATAL: database "app" does not exist`). | Smoke test GAP; create databases with `psql` in app bootstrap. |
| F-29 | PostgreSQL | `version = "16"` is ignored: the server is `postgres:17-alpine` (**17.11**). | Smoke test GAP. |
| F-30 | Network exposure | Docker-backed data services are published on **0.0.0.0** of the host (Postgres :52872, MySQL :50633, Redis :6379, ACR :5001) — reachable from the LAN — and firewall rules (`vnet-only` 10.40.0.0/16) are not enforced. Run the lab only on trusted networks / with the host firewall on. | Documented; lab traffic stays on the compose network. |
| F-31 | Restarts | After a host/Docker restart floci-az returns (compose `restart: unless-stopped`) but every container it launched (ACR registry, AKS k3s, Postgres, MySQL, Redis) stays **Exited** while ARM still lists the resources. Restarted by hand, the k3s node exits with `failed to find interface with specified node ip`: Docker gave it a new address. | `scripts/recover-after-restart.sh` restarts them and reattaches AKS at its recorded IP. |
| F-24 | Timing | Key Vault ~2m, policy assignment ~1m35s, PostgreSQL ~1m24s per create. | None. |

## Coverage (Terraform, azurerm 4.81.0, floci-az 0.15.0)

| Managed by Terraform and converging (36 resources) | Gated (`include_known_emulator_gaps`) |
|---|---|
| Resource group; VNet, 4 subnets, NSG + association, public IP, NIC, private DNS zone + link; user-assigned identity; storage account, blob container, queue; Key Vault, secret, key; ACR; PostgreSQL flexible server + database + firewall rule; Redis; Container Apps environment + app; ACI container group; API Management; Linux VM (mocked); Email Communication Service; Policy definition + RG assignment | Log Analytics (F-02); storage table (F-08); AKS + node pool (F-16); role assignments (F-17); Cosmos DB, Service Bus, Event Hubs, App Configuration, SignalR, App Service plan + Function app, action group (F-14); Azure SQL (F-18); Communication Service (F-19); MySQL (F-22); Event Grid (F-23) |
