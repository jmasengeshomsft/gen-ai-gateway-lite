locals {
  # Common tags applied to all resources
  common_tags = {
    Project   = "Gen AI Gateway Lite"
    ManagedBy = "Terraform"
  }

  service_deployments = {
    for combo in flatten([
      for svc_key, svc in var.openai_config : [
        for dep_key, dep in var.openai_deployments : {
          key      = "${svc_key}-${dep_key}"
          svc_key  = svc_key
          svc      = svc
          dep_key  = dep_key
          dep      = dep
        }
      ]
    ]) : combo.key => {
      svc_key = combo.svc_key
      svc     = combo.svc
      dep_key = combo.dep_key
      dep     = combo.dep
    }
  }

  # Build KQL inline pricing datatable from openai_deployments (only those with prices set)
  pricing_models = [
    for k, d in var.openai_deployments : d
    if d.input_price != null && d.output_price != null
  ]
  pricing_datatable_rows = join(",\r\n", [
    for m in local.pricing_models :
    "    \"${m.deployment_name}\", ${m.input_price}, ${m.output_price}"
  ])
  pricing_datatable = "let pricingData = datatable(Model: string, InputPrice: real, OutputPrice: real)[\r\n${local.pricing_datatable_rows}\r\n];\r\n"

  # KQL datatable mapping APIM subscription GUIDs → display names
  subscription_names_rows = join(",\r\n", concat(
    [for k, v in var.apim_tenants :
      "    \"${azurerm_api_management_subscription.tenant[k].subscription_id}\", \"${v.display_name}\""
    ],
    ["    \"${azurerm_api_management_subscription.apim-api-subscription-openai.subscription_id}\", \"Default (Lab)\""]
  ))
  subscription_names_datatable = "let subscriptionNames = datatable(SubscriptionId: string, SubscriptionName: string)[\r\n${local.subscription_names_rows}\r\n];\r\n"

  # Build per-tenant subscription objects for the policy template
  tenant_subscriptions = [
    for k, v in var.apim_tenants : {
      subscription_id    = azurerm_api_management_subscription.tenant[k].subscription_id
      display_name       = v.display_name
      tokens_per_minute  = coalesce(v.tokens_per_minute, var.default_tokens_per_minute)
      token_quota        = coalesce(v.token_quota, var.default_token_quota)
      token_quota_period = coalesce(v.token_quota_period, var.default_token_quota_period)
    }
  ]
}


resource "azurerm_resource_group" "rg" {
  name     = "${var.resource_group_name}-${var.app_suffix}-rg"
  location = var.resource_group_location
  tags     = local.common_tags
}


# Virtual Network with two subnets: apim (/27) + private-endpoints (/25)
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.vnet_name}-${var.app_suffix}"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "subnet_apim" {
  name                 = "apim"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_apim_address_space]

  service_endpoints = [
    "Microsoft.CognitiveServices"
  ]

  delegation {
    name = "webserverfarmdelegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_network_security_group" "apim_nsg" {
  name                = "apim-nsg-${var.app_suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "apim_nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet_apim.id
  network_security_group_id = azurerm_network_security_group.apim_nsg.id
}

resource "azurerm_subnet" "subnet_private_endpoints" {
  name                 = "private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_private_endpoints_address_space]
}


resource "azurerm_cognitive_account" "ai-services" {
  for_each = var.openai_config

  name                               = "${each.value.name}-${var.app_suffix}"
  location                           = each.value.location
  resource_group_name                = azurerm_resource_group.rg.name
  kind                               = "AIServices"
  sku_name                           = var.openai_sku
  local_auth_enabled                 = true
  public_network_access_enabled      = true
  outbound_network_access_restricted = true
  custom_subdomain_name              = "${each.value.name}-${var.app_suffix}"

  network_acls {
    default_action = "Deny"
    virtual_network_rules {
      subnet_id = azurerm_subnet.subnet_apim.id
    }
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [custom_subdomain_name]
  }
}

resource "azurerm_monitor_diagnostic_setting" "ai_services_diag" {
  for_each            = var.openai_config
  name                = "${each.value.name}-diag-${var.app_suffix}"
  target_resource_id  = azurerm_cognitive_account.ai-services[each.key].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.apim_log_analytics.id

  enabled_log {
    category = "Audit"
  }

  enabled_log {
    category = "RequestResponse"
  }

  enabled_log {
    category = "Trace"
  }

  enabled_metric {
    category = "AllMetrics"
  }
  
}

# APIM Platform Diagnostic Settings → Log Analytics Workspace
# Enables ApiManagementGatewayLogs + ApiManagementGatewayLlmLog resource-specific tables
resource "azurerm_monitor_diagnostic_setting" "apim_diagnostics" {
  name                           = "apimDiagnosticSettings"
  target_resource_id             = azapi_resource.apim.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.apim_log_analytics.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_log {
    category = "GatewayLlmLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}


// Attach a RAIPolicy (content filter) to each AI service
resource "azapi_resource" "ai_content_filter" {
  for_each  = var.openai_config
  type      = "Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01"
  parent_id = azurerm_cognitive_account.ai-services[each.key].id
  name      = lower(replace("content-filter-${each.value.name}-${var.app_suffix}", "-", ""))

  body = {
    properties = {
       basePolicyName = "Microsoft.Default",
       contentFilters = [
        { name = "hate", blocking = true, enabled = true, severityThreshold = "High", source = "Prompt" },
        { name = "sexual", blocking = true, enabled = true, severityThreshold = "High", source = "Prompt" },
        { name = "selfharm", blocking = true, enabled = true, severityThreshold = "High", source = "Prompt" },
        { name = "violence", blocking = true, enabled = true, severityThreshold = "High", source = "Prompt" },
        { name = "hate", blocking = true, enabled = true, severityThreshold = "High", source = "Completion" },
        { name = "sexual", blocking = true, enabled = true, severityThreshold = "High", source = "Completion" },
        { name = "selfharm", blocking = true, enabled = true, severityThreshold = "High", source = "Completion" },
        { name = "violence", blocking = true, enabled = true, severityThreshold = "High", source = "Completion" },
        { name = "jailbreak", blocking = true, enabled = true, source = "Prompt" },
        { name = "protected_material_text", blocking = true, enabled = true, source = "Completion" },
        { name = "protected_material_code", blocking = true, enabled = true, source = "Completion" }
      ]
      mode = "Default"
    }
  }
}

# Add a local to store the predictable rai_policy_name for each service
locals {
  rai_policy_names = {
    for svc_key, svc in var.openai_config :
    svc_key => lower(replace("content-filter-${svc.name}-${var.app_suffix}", "-", ""))
  }
}

resource "azurerm_cognitive_deployment" "deploy" {
  for_each = local.service_deployments

  name                 = each.value.dep.deployment_name
  cognitive_account_id = azurerm_cognitive_account.ai-services[each.value.svc_key].id

  sku {
    name     = "GlobalStandard"
    capacity = each.value.dep.model_capacity
  }

  model {
    format  = "OpenAI"
    name    = each.value.dep.model_name
    version = each.value.dep.model_version
  }

  rai_policy_name = local.rai_policy_names[each.value.svc_key]

  depends_on = [azapi_resource.ai_content_filter]
}

# Terraform azurerm provider doesn't support yet creating API Management instances with v2 SKU.
resource "azapi_resource" "apim" {
  type                      = "Microsoft.ApiManagement/service@2024-06-01-preview"
  name                      = "${var.apim_resource_name}-${var.app_suffix}"
  parent_id                 = azurerm_resource_group.rg.id
  location                  = var.apim_resource_location # StandardV2 SKU not available in all regions
  schema_validation_enabled = true
  tags                      = local.common_tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = {
      name     = var.apim_sku
      capacity = var.apim_sku_capacity
    }
    properties = {
      publisherEmail      = "admin@contoso.com"     # TODO: update for your org
      publisherName       = "Contoso"                # TODO: update for your org
      virtualNetworkType  = "External"
      virtualNetworkConfiguration = {
        subnetResourceId = azurerm_subnet.subnet_apim.id
      }
      publicNetworkAccess = "Enabled"
    }
  }

  response_export_values = ["*"]
  depends_on = [ azurerm_subnet_network_security_group_association.apim_nsg_assoc ]
}

resource "azurerm_role_assignment" "Cognitive-Services-OpenAI-User" {
  for_each = var.openai_config

  scope                = azurerm_cognitive_account.ai-services[each.key].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azapi_resource.apim.identity.0.principal_id
}

resource "azurerm_api_management_api" "apim-api-openai" {
  name                  = "apim-api-openai"
  resource_group_name   = azurerm_resource_group.rg.name
  api_management_name   = azapi_resource.apim.name
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


resource "azurerm_api_management_product" "openai_product" {
  product_id           = "openai-product"
  display_name         = "OpenAI APIs"
  description          = "Product exposing Azure OpenAI endpoints"
  api_management_name  = azapi_resource.apim.name
  resource_group_name  = azurerm_resource_group.rg.name

  subscription_required = true
  approval_required     = false
  published             = true
}

// 2. Add the OpenAI API to that product
resource "azurerm_api_management_product_api" "openai_product_api" {
  product_id           = azurerm_api_management_product.openai_product.product_id
  api_management_name  = azapi_resource.apim.name
  resource_group_name  = azurerm_resource_group.rg.name
  api_name             = azurerm_api_management_api.apim-api-openai.name
}

### Azure Content Safety — enables llm-content-safety APIM policy
resource "azurerm_cognitive_account" "content_safety" {
  name                  = "contentsafety-${var.app_suffix}"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  sku_name              = "S0"
  kind                  = "ContentSafety"
  custom_subdomain_name = lower("contentsafety-${var.app_suffix}")
  public_network_access_enabled = true
  local_auth_enabled    = true

  network_acls {
    default_action = "Deny"
    virtual_network_rules {
      subnet_id = azurerm_subnet.subnet_apim.id
    }
  }

  tags = local.common_tags
}

# Grant APIM managed identity "Cognitive Services User" on the Content Safety resource
resource "azurerm_role_assignment" "content_safety_user" {
  scope                = azurerm_cognitive_account.content_safety.id
  role_definition_name = "Cognitive Services User"
  principal_id         = azapi_resource.apim.identity.0.principal_id
}

# APIM backend for Content Safety (used by llm-content-safety policy)
resource "azurerm_api_management_backend" "content_safety_backend" {
  name                = "content-safety-backend"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azapi_resource.apim.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.content_safety.endpoint}"
}

resource "azurerm_api_management_backend" "apim-backend-openai" {
  for_each = var.openai_config

  name                = each.value.name
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azapi_resource.apim.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.ai-services[each.key].endpoint}openai"
}

resource "azapi_update_resource" "apim-backend-circuit-breaker" {
  for_each = var.openai_config

  type        = "Microsoft.ApiManagement/service/backends@2023-09-01-preview"
  resource_id = azurerm_api_management_backend.apim-backend-openai[each.key].id

  body = {
    properties = {
      circuitBreaker = {
        rules = [
          {
            failureCondition = {
              count = 1
              errorReasons = [
                "Server errors"
              ]
              interval = "PT5M"
              statusCodeRanges = [
                {
                  min = 429
                  max = 429
                }
              ]
            }
            name             = "openAIBreakerRule"
            tripDuration     = "PT1M"
            acceptRetryAfter = true // respects the Retry-After header
          }
        ]
      }
    }
  }
}

resource "azapi_resource" "apim-backend-pool-openai" {
  type                      = "Microsoft.ApiManagement/service/backends@2023-09-01-preview"
  name                      = "apim-backend-pool"
  parent_id                 = azapi_resource.apim.id
  schema_validation_enabled = false

  body = {
    properties = {
      type = "Pool"
      pool = {
        services = [
          for k, v in var.openai_config :
          {
            id       = azurerm_api_management_backend.apim-backend-openai[k].id
            priority = v.priority
            weight   = v.weight
          }
        ]
      }
    }
  }
}

resource "azurerm_api_management_api_policy" "apim-openai-policy-openai" {
  api_name            = azurerm_api_management_api.apim-api-openai.name
  api_management_name = azurerm_api_management_api.apim-api-openai.api_management_name
  resource_group_name = azurerm_api_management_api.apim-api-openai.resource_group_name

  xml_content = templatefile("${path.module}/policy.xml.tftpl", {
    backend_id                 = azapi_resource.apim-backend-pool-openai.name
    content_safety_backend_id  = azurerm_api_management_backend.content_safety_backend.name
    tenant_subscriptions        = local.tenant_subscriptions
    default_tokens_per_minute   = var.default_tokens_per_minute
    default_token_quota         = var.default_token_quota
    default_token_quota_period  = var.default_token_quota_period
  })
}

# ── Default (lab) APIM subscription ──────────────────────────────────────────
resource "azurerm_api_management_subscription" "apim-api-subscription-openai" {
  display_name        = "apim-api-subscription-openai"
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  api_id              = replace(azurerm_api_management_api.apim-api-openai.id, "/;rev=.*/", "")
  allow_tracing       = true
  state               = "active"
}

# ── Per-tenant APIM subscriptions ────────────────────────────────────────────
resource "azurerm_api_management_subscription" "tenant" {
  for_each = var.apim_tenants

  display_name        = each.value.display_name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  api_id              = replace(azurerm_api_management_api.apim-api-openai.id, "/;rev=.*/", "")
  allow_tracing       = true
  state               = each.value.state
}

### Monitoring and Logging
# 1. Create a log analytics workspace for the APIM instance
resource "azurerm_log_analytics_workspace" "apim_log_analytics" {
  name                = "${var.apim_resource_name}-log-analytics-${var.app_suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_application_insights" "apim_ai_logger" {
  name                = "${var.apim_resource_name}-app-insights-${var.app_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  application_type    = "web"
  retention_in_days   = 30
  workspace_id        = azurerm_log_analytics_workspace.apim_log_analytics.id
  tags                = local.common_tags
}

// 2. Create an APIM logger that points at the AppInsights instance
resource "azapi_resource" "apim_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2021-12-01-preview"
  parent_id = azapi_resource.apim.id
  name      = "appinsights"

  body = {
    properties = {
      loggerType  = "applicationInsights"
      description = "Logger for OpenAI APIs"
      isBuffered  = false
      credentials = {
        instrumentationKey = azurerm_application_insights.apim_ai_logger.instrumentation_key
      }
      resourceId = azurerm_application_insights.apim_ai_logger.id
    }
  }
}

// 3. Enable diagnostics on the OpenAI API to send traces to that logger
resource "azapi_resource" "apim_api_diagnostic" {
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  parent_id   = azurerm_api_management_api.apim-api-openai.id
  name        = "applicationinsights"

  body = {
    properties = {
      alwaysLog               = "allErrors"
      httpCorrelationProtocol = "W3C"
      logClientIp             = true
      loggerId                = azapi_resource.apim_logger.id
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

// 4. Azure Monitor logger — enables ApiManagementGatewayLlmLog resource-specific table in LAW
// Note: APIM auto-creates an "azuremonitor" logger on service creation,
// so we use azapi_update_resource to configure the existing resource.
resource "azapi_update_resource" "apim_azure_monitor_logger" {
  type        = "Microsoft.ApiManagement/service/loggers@2024-06-01-preview"
  resource_id = "${azapi_resource.apim.id}/loggers/azuremonitor"

  body = {
    properties = {
      loggerType = "azureMonitor"
      isBuffered = false
    }
  }
}

// 5. Azure Monitor diagnostic on the OpenAI API — LLM-specific logging (token counts, messages)
resource "azapi_resource" "apim_api_diagnostic_azuremonitor" {
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview"
  parent_id = azurerm_api_management_api.apim-api-openai.id
  name      = "azuremonitor"

  body = {
    properties = {
      alwaysLog   = "allErrors"
      logClientIp = true
      loggerId    = azapi_update_resource.apim_azure_monitor_logger.id
      verbosity   = "verbose"
      sampling = {
        samplingType = "fixed"
        percentage   = 100
      }
      frontend = {
        request  = { headers = [], body = { bytes = 0 } }
        response = { headers = [], body = { bytes = 0 } }
      }
      backend = {
        request  = { headers = [], body = { bytes = 0 } }
        response = { headers = [], body = { bytes = 0 } }
      }
      largeLanguageModel = {
        logs = "enabled"
        requests = {
          maxSizeInBytes = 262144
          messages       = "all"
        }
        responses = {
          maxSizeInBytes = 262144
          messages       = "all"
        }
      }
    }
  }
}

# Old workbook resources removed — dashboard is now deployed via dashboard.tf

### Alert Rules and Notifications (conditional on monitoring_alerting.enabled)
# Action Group for email notifications
resource "azurerm_monitor_action_group" "apim_alerts" {
  count               = var.monitoring_alerting.enabled ? 1 : 0
  name                = "apim-alerts-${var.app_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "apimalerts"

  dynamic "email_receiver" {
    for_each = var.monitoring_alerting.alert_emails
    content {
      name          = "alert-email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }

  tags = merge(local.common_tags, {
    Environment = "monitoring"
    Purpose     = "apim-alerting"
  })
}

# Metric Alert Rule for APIM 4xx errors
resource "azurerm_monitor_metric_alert" "apim_4xx_errors" {
  count               = var.monitoring_alerting.enabled ? 1 : 0
  name                = "apim-4xx-errors-alert-${var.app_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azapi_resource.apim.id]
  description         = "Alert when APIM has more than ${var.monitoring_alerting.error_4xx_threshold} 4xx errors in 5 minutes"
  severity            = var.monitoring_alerting.alert_severity
  enabled             = true
  auto_mitigate       = true
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ApiManagement/service"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.monitoring_alerting.error_4xx_threshold

    dimension {
      name     = "BackendResponseCode"
      operator = "Include"
      values   = ["4*"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.apim_alerts[0].id
  }

  tags = merge(local.common_tags, {
    Environment = "monitoring"
    Purpose     = "apim-error-monitoring"
  })
}

# Metric Alert Rule for APIM capacity utilization
resource "azurerm_monitor_metric_alert" "apim_capacity" {
  count               = var.monitoring_alerting.enabled ? 1 : 0
  name                = "apim-capacity-alert-${var.app_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azapi_resource.apim.id]
  description         = "Alert when APIM capacity utilization >= ${var.monitoring_alerting.capacity_threshold}%"
  severity            = var.monitoring_alerting.alert_severity
  enabled             = true
  auto_mitigate       = true
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.ApiManagement/service"
    metric_name      = "Capacity"
    aggregation      = "Average"
    operator         = "GreaterThanOrEqual"
    threshold        = var.monitoring_alerting.capacity_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.apim_alerts[0].id
  }

  tags = merge(local.common_tags, {
    Environment = "monitoring"
    Purpose     = "apim-capacity-monitoring"
  })
}

# Metric Alert Rule for APIM latency
resource "azurerm_monitor_metric_alert" "apim_latency" {
  count               = var.monitoring_alerting.enabled ? 1 : 0
  name                = "apim-latency-alert-${var.app_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azapi_resource.apim.id]
  description         = "Alert when APIM avg response time > ${var.monitoring_alerting.latency_threshold_ms}ms"
  severity            = var.monitoring_alerting.alert_severity
  enabled             = true
  auto_mitigate       = true
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ApiManagement/service"
    metric_name      = "Duration"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.monitoring_alerting.latency_threshold_ms
  }

  action {
    action_group_id = azurerm_monitor_action_group.apim_alerts[0].id
  }

  tags = merge(local.common_tags, {
    Environment = "monitoring"
    Purpose     = "apim-latency-monitoring"
  })
}

### Auto Scaling Configuration (conditional on autoscale.enabled)
resource "azurerm_monitor_autoscale_setting" "apim_autoscale" {
  count               = var.autoscale.enabled ? 1 : 0
  name                = "apim-autoscale-${var.app_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  target_resource_id  = azapi_resource.apim.id

  profile {
    name = "default"

    capacity {
      default = var.apim_sku_capacity
      minimum = var.autoscale.min_capacity
      maximum = var.autoscale.max_capacity
    }

    # Scale out rule — increase capacity when utilization > threshold
    rule {
      metric_trigger {
        metric_name        = "Capacity"
        metric_resource_id = azapi_resource.apim.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.autoscale.scale_out_threshold
        metric_namespace   = "Microsoft.ApiManagement/service"
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = var.autoscale.cooldown_period
      }
    }

    # Scale in rule — decrease capacity when utilization < threshold
    rule {
      metric_trigger {
        metric_name        = "Capacity"
        metric_resource_id = azapi_resource.apim.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.autoscale.scale_in_threshold
        metric_namespace   = "Microsoft.ApiManagement/service"
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = var.autoscale.cooldown_period
      }
    }
  }

  # Notification for scaling events (reuses monitoring alert emails if available)
  dynamic "notification" {
    for_each = length(var.monitoring_alerting.alert_emails) > 0 ? [1] : []
    content {
      email {
        send_to_subscription_administrator    = false
        send_to_subscription_co_administrator = false
        custom_emails                         = var.monitoring_alerting.alert_emails
      }
    }
  }

  tags = merge(local.common_tags, {
    Environment = "monitoring"
    Purpose     = "apim-autoscaling"
  })
}

### Global Policy (IP filtering + security headers)
resource "azurerm_api_management_policy" "global_policy" {
  api_management_id   = azapi_resource.apim.id
  xml_content         = file("global-policy.xml")
}