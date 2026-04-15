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

# Register Managed Redis as APIM's external cache.
# Once configured, llm-token-limit, quota-by-key, and rate-limit-by-key
# policies automatically write their counters here — no policy changes needed.
resource "azurerm_api_management_redis_cache" "apim_external_cache" {
  name              = "external-cache"
  api_management_id = azapi_resource.apim.id
  connection_string = "${azurerm_managed_redis.apim_cache.hostname}:${azurerm_managed_redis.apim_cache.default_database[0].port},password=${azurerm_managed_redis.apim_cache.default_database[0].primary_access_key},ssl=True,abortConnect=False"
  redis_cache_id    = azurerm_managed_redis.apim_cache.id
  description       = "Shared counter store for token quota and rate-limit policies across all APIM scale units"
}
