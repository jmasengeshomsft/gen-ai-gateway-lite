# ─────────────────────────────────────────────────────────────────────────────
# Azure Managed Redis — Balanced_B0 (cheapest tier, lab/dev)
#
# Why: APIM's llm-token-limit policy stores quota counters in local in-memory
# cache by default. With multiple scale units or restarts, each unit gets an
# independent counter and quotas reset on every run. Configuring an external
# Redis cache gives all units a single shared, persistent counter store.
# ─────────────────────────────────────────────────────────────────────────────

resource "azurerm_managed_redis" "apim_cache" {
  name                      = "redis-${var.app_suffix}"
  location                  = azurerm_resource_group.rg.location
  resource_group_name       = azurerm_resource_group.rg.name

  # Balanced_B0: cheapest Managed Redis SKU
  # high_availability_enabled = false saves cost in non-prod environments
  sku_name                  = "Balanced_B0"
  high_availability_enabled = false

  default_database {
    # Enable access key auth so we can build the connection string for APIM
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
  }

  tags = local.common_tags
}

# Register Managed Redis as the external cache for both APIM instances.
# Used by the custom Redis quota counter (cache-lookup-value / cache-store-value)
# to share a single globally-consistent token counter across all processes and replicas.
# NOTE: llm-token-limit does NOT use this cache — its counters are always per-process.
resource "azurerm_api_management_redis_cache" "apim_external_cache" {
  name              = "default"
  api_management_id = azapi_resource.apim.id
  connection_string = "${azurerm_managed_redis.apim_cache.hostname}:${azurerm_managed_redis.apim_cache.default_database[0].port},password=${azurerm_managed_redis.apim_cache.default_database[0].primary_access_key},ssl=True,abortConnect=False"
  redis_cache_id    = azurerm_managed_redis.apim_cache.id
  description       = "Shared Redis quota counter store — used by cache-store-value/cache-lookup-value across all v2 replicas"
}
