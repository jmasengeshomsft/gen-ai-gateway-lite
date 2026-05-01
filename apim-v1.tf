# ══════════════════════════════════════════════════════════════════════════════
# APIM Standard v1 (Classic) — for quota counter comparison vs Standard v2
#
# Purpose: llm-token-limit counters in the Classic tier run on dedicated VMs,
# not ACA replicas, so they don't exhibit the per-replica counter fragmentation
# seen in StandardV2. This instance lets us compare quota behaviour side-by-side.
#
# NOTE: Classic Standard provisioning deploys dedicated VMs and takes 30–45 min.
# ══════════════════════════════════════════════════════════════════════════════

# ── Networking ────────────────────────────────────────────────────────────────
# Uses 10.0.254.96/27 — the unused /27 slot between the ACA-private and
# private-endpoints subnets in the 10.0.254.0/24 VNet.

resource "azurerm_subnet" "subnet_apim_v1" {
  name                 = "apim-v1"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_apim_v1_address_space]

  # Needed so the OpenAI network_acls virtual_network_rules trust this subnet.
  service_endpoints = ["Microsoft.CognitiveServices"]

  # Classic APIM does NOT need the Microsoft.Web/serverFarms delegation
  # that the v2 ACA-based tier requires. No delegation block here.
}

resource "azurerm_network_security_group" "apim_nsg_v1" {
  name                = "apim-v1-nsg-${var.app_suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.common_tags

  # REQUIRED for Classic APIM in External VNet mode.
  # Without port 3443 from ApiManagement the management plane cannot reach the
  # gateway and the instance will show as Unhealthy in the portal.
  security_rule {
    name                       = "AllowApiManagementManagement"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  # Health probes from the Azure Load Balancer fronting Classic APIM.
  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }

  # Allow inbound HTTPS from clients (internet → gateway public IP → APIM VM).
  # Required for External VNet mode: without this the NSG default-deny blocks
  # all traffic that isn't from ApiManagement or AzureLoadBalancer.
  security_rule {
    name                       = "AllowInternetHTTPS"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim_v1_nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet_apim_v1.id
  network_security_group_id = azurerm_network_security_group.apim_nsg_v1.id
}

# ── APIM Standard v1 instance ─────────────────────────────────────────────────

resource "azurerm_api_management" "apim_v1" {
  name                = "apim-v1-${var.app_suffix}"
  location            = var.apim_resource_location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_email     = "admin@contoso.com"
  publisher_name      = "Contoso"

  # Standard_1 = Classic Standard tier, 1 unit (dedicated VM — no ACA replicas)
  sku_name = "Developer_1"

  identity {
    type = "SystemAssigned"
  }

  # External = gateway is publicly accessible; management plane also public.
  # The APIM VM reaches OpenAI via the subnet service endpoint.
  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.subnet_apim_v1.id
  }

  tags = local.common_tags

  # NSG must be associated before APIM attempts to use the subnet.
  depends_on = [azurerm_subnet_network_security_group_association.apim_v1_nsg_assoc]
}

# ── OpenAI access ─────────────────────────────────────────────────────────────

resource "azurerm_role_assignment" "apim_v1_openai_user" {
  for_each = var.openai_config

  scope                = azurerm_cognitive_account.ai-services[each.key].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim_v1.identity[0].principal_id
}

# ── Backend pool (same OpenAI endpoints as v2) ────────────────────────────────

resource "azurerm_api_management_backend" "apim_v1_backend_openai" {
  for_each = var.openai_config

  name                = each.value.name
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim_v1.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.ai-services[each.key].endpoint}openai"
}

resource "azapi_update_resource" "apim_v1_backend_circuit_breaker" {
  for_each = var.openai_config

  type        = "Microsoft.ApiManagement/service/backends@2023-09-01-preview"
  resource_id = azurerm_api_management_backend.apim_v1_backend_openai[each.key].id

  body = {
    properties = {
      circuitBreaker = {
        rules = [
          {
            failureCondition = {
              count        = 1
              errorReasons = ["Server errors"]
              interval     = "PT5M"
              statusCodeRanges = [{
                min = 429
                max = 429
              }]
            }
            name             = "openAIBreakerRule"
            tripDuration     = "PT1M"
            acceptRetryAfter = true
          }
        ]
      }
    }
  }
}

resource "azapi_resource" "apim_v1_backend_pool" {
  type                      = "Microsoft.ApiManagement/service/backends@2023-09-01-preview"
  name                      = "apim-backend-pool"
  parent_id                 = azurerm_api_management.apim_v1.id
  schema_validation_enabled = false

  body = {
    properties = {
      type = "Pool"
      pool = {
        services = [
          for k, v in var.openai_config : {
            id       = azurerm_api_management_backend.apim_v1_backend_openai[k].id
            priority = v.priority
            weight   = v.weight
          }
        ]
      }
    }
  }
}

# ── OpenAI API ────────────────────────────────────────────────────────────────

resource "azurerm_api_management_api" "apim_v1_api_openai" {
  name                  = "apim-api-openai"
  resource_group_name   = azurerm_resource_group.rg.name
  api_management_name   = azurerm_api_management.apim_v1.name
  revision              = "1"
  description           = "Azure OpenAI APIs for completions and search"
  display_name          = "OpenAI"
  path                  = "openai"
  protocols             = ["https"]
  service_url           = null
  subscription_required = true
  api_type              = "http"

  import {
    content_format = "openapi-link"
    content_value  = var.openai_api_spec_url
  }

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }
}

resource "azurerm_api_management_product" "apim_v1_openai_product" {
  product_id            = "openai-product"
  display_name          = "OpenAI APIs"
  api_management_name   = azurerm_api_management.apim_v1.name
  resource_group_name   = azurerm_resource_group.rg.name
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "apim_v1_openai_product_api" {
  product_id          = azurerm_api_management_product.apim_v1_openai_product.product_id
  api_management_name = azurerm_api_management.apim_v1.name
  resource_group_name = azurerm_resource_group.rg.name
  api_name            = azurerm_api_management_api.apim_v1_api_openai.name
}

# ── Subscriptions (mirror all v2 tenants) ─────────────────────────────────────
# New subscription GUIDs are auto-assigned — they differ from v2, which is why
# the policy local below re-evaluates them per instance.

resource "azurerm_api_management_subscription" "apim_v1_default" {
  display_name        = "apim-api-subscription-openai"
  api_management_name = azurerm_api_management.apim_v1.name
  resource_group_name = azurerm_resource_group.rg.name
  api_id              = replace(azurerm_api_management_api.apim_v1_api_openai.id, "/;rev=.*/", "")
  allow_tracing       = true
  state               = "active"
}

resource "azurerm_api_management_subscription" "apim_v1_tenant" {
  for_each = var.apim_tenants

  display_name        = each.value.display_name
  api_management_name = azurerm_api_management.apim_v1.name
  resource_group_name = azurerm_resource_group.rg.name
  api_id              = replace(azurerm_api_management_api.apim_v1_api_openai.id, "/;rev=.*/", "")
  allow_tracing       = true
  state               = each.value.state
}

# ── Policy — same template as v2, wired to v1 subscription IDs ───────────────

locals {
  tenant_subscriptions_v1 = [
    for k, v in var.apim_tenants : {
      subscription_id    = azurerm_api_management_subscription.apim_v1_tenant[k].subscription_id
      display_name       = v.display_name
      tokens_per_minute  = coalesce(v.tokens_per_minute, var.default_tokens_per_minute)
      token_quota        = coalesce(v.token_quota, var.default_token_quota)
      token_quota_period = coalesce(v.token_quota_period, var.default_token_quota_period)
      quota_date_fmt     = local.quota_period_config[coalesce(v.token_quota_period, var.default_token_quota_period)].date_fmt
      quota_ttl_seconds  = local.quota_period_config[coalesce(v.token_quota_period, var.default_token_quota_period)].ttl_seconds
    }
  ]
}

resource "azurerm_api_management_api_policy" "apim_v1_openai_policy" {
  api_name            = azurerm_api_management_api.apim_v1_api_openai.name
  api_management_name = azurerm_api_management_api.apim_v1_api_openai.api_management_name
  resource_group_name = azurerm_resource_group.rg.name

  # Ensure the external Redis cache is registered before the policy that uses it
  depends_on = [azurerm_api_management_redis_cache.apim_v1_external_cache]

  xml_content = templatefile("${path.module}/policy.xml.tftpl", {
    backend_id                 = azapi_resource.apim_v1_backend_pool.name
    content_safety_backend_id  = ""
    enable_content_safety      = false
    tenant_subscriptions       = local.tenant_subscriptions_v1
    default_tokens_per_minute  = var.default_tokens_per_minute
    default_token_quota        = var.default_token_quota
    default_token_quota_period = var.default_token_quota_period
    default_quota_date_fmt     = local.quota_period_config[var.default_token_quota_period].date_fmt
    default_quota_ttl_seconds  = local.quota_period_config[var.default_token_quota_period].ttl_seconds
  })
}

# ── Global policy — same IP filter as v2 ─────────────────────────────────────

resource "azurerm_api_management_policy" "apim_v1_global_policy" {
  api_management_id = azurerm_api_management.apim_v1.id
  xml_content       = file("global-policy.xml")
}

# ── Logger (App Insights) ─────────────────────────────────────────────────────
# Reuses the existing App Insights workspace so both APIM instances appear in
# the same telemetry scope, making it easy to compare gateway behaviour.

resource "azurerm_api_management_logger" "apim_v1_logger" {
  name                = "appinsights"
  api_management_name = azurerm_api_management.apim_v1.name
  resource_group_name = azurerm_resource_group.rg.name
  resource_id         = azurerm_application_insights.apim_ai_logger.id
  description         = "Logger for OpenAI APIs (v1 Classic)"
  buffered            = false

  application_insights {
    instrumentation_key = azurerm_application_insights.apim_ai_logger.instrumentation_key
  }
}

resource "azapi_resource" "apim_v1_api_diagnostic" {
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  parent_id = azurerm_api_management_api.apim_v1_api_openai.id
  name      = "applicationinsights"

  body = {
    properties = {
      alwaysLog               = "allErrors"
      httpCorrelationProtocol = "W3C"
      logClientIp             = true
      loggerId                = azurerm_api_management_logger.apim_v1_logger.id
      metrics                 = true
      verbosity               = "verbose"
      sampling = {
        samplingType = "fixed"
        percentage   = 100
      }
      frontend = {
        request = {
          headers = ["Content-type", "User-agent", "x-ms-region", "x-ratelimit-remaining-tokens", "x-ratelimit-remaining-requests"]
          body    = { bytes = 8192 }
        }
        response = {
          headers = ["Content-type", "User-agent", "x-ms-region", "x-ratelimit-remaining-tokens", "x-ratelimit-remaining-requests"]
          body    = { bytes = 8192 }
        }
      }
      backend = {
        request = {
          headers = ["Content-type", "User-agent", "x-ms-region", "x-ratelimit-remaining-tokens", "x-ratelimit-remaining-requests"]
          body    = { bytes = 8192 }
        }
        response = {
          headers = ["Content-type", "User-agent", "x-ms-region", "x-ratelimit-remaining-tokens", "x-ratelimit-remaining-requests"]
          body    = { bytes = 8192 }
        }
      }
    }
  }
}
