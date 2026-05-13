output "primary_resource_group" {
  value = {
    name         = azurerm_resource_group.rg.name
    location     = azurerm_resource_group.rg.location
    subscription = var.subscription_id
  }
  description = "Primary resource group information"
}

output "apim_gateway_url" {
  value = azapi_resource.apim.output.properties.gatewayUrl
  description = "API Management Gateway URL"
}

output "apim_subscription_key" {
  value = azurerm_api_management_subscription.apim-api-subscription-openai.primary_key
  description = "API Management subscription key (default lab)"
  sensitive = true
}

output "apim_tenant_subscription_keys" {
  value = {
    for k, sub in azurerm_api_management_subscription.tenant : k => {
      display_name = sub.display_name
      primary_key  = sub.primary_key
    }
  }
  description = "Per-tenant APIM subscription keys"
  sensitive   = true
}

output "redis_hostname" {
  value       = azurerm_managed_redis.apim_cache.hostname
  description = "Managed Redis hostname (Balanced_B0) — registered as APIM external cache"
}

output "tenant_config" {
  value = {
    for k, v in var.apim_tenants : k => {
      display_name       = v.display_name
      tokens_per_minute  = coalesce(v.tokens_per_minute, var.default_tokens_per_minute)
      token_quota        = coalesce(v.token_quota, var.default_token_quota)
      token_quota_period = coalesce(v.token_quota_period, var.default_token_quota_period)
    }
  }
  description = "Per-tenant quota configuration (for test tooling — quota, period, TPM)"
}
