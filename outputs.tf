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
