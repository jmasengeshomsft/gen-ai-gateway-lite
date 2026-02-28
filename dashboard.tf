# ──────────────────────────────────────────────────────────────────────────────
# Azure Portal Dashboard — APIM ❤️ AI Gateway (converted from Bicep on main)
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # ── KQL queries ────────────────────────────────────────────────────────────

  kql_token_by_model = "ApiManagementGatewayLlmLog\r\n| where TimeGenerated > ago(24h)\r\n| where TotalTokens > 0 and isnotempty(DeploymentName)\r\n| summarize TotalPromptTokens = sum(PromptTokens), TotalCompletionTokens = sum(CompletionTokens), TotalTokens = sum(TotalTokens) by DeploymentName\r\n| order by TotalTokens desc\r\n"

  kql_token_by_subscription = "${local.subscription_names_datatable}ApiManagementGatewayLlmLog\r\n| where TimeGenerated > ago(24h)\r\n| where TotalTokens > 0 and isnotempty(DeploymentName)\r\n| join kind=leftouter (\r\n    ApiManagementGatewayLogs\r\n    | where TimeGenerated > ago(24h)\r\n    | where isnotempty(ApimSubscriptionId)\r\n    | summarize ApimSubscriptionId = any(ApimSubscriptionId) by CorrelationId\r\n) on CorrelationId\r\n| extend SubscriptionId = iif(isempty(ApimSubscriptionId), \"unknown\", ApimSubscriptionId)\r\n| lookup subscriptionNames on SubscriptionId\r\n| extend Subscription = coalesce(SubscriptionName, SubscriptionId)\r\n| summarize TotalTokens = sum(TotalTokens) by Subscription\r\n| order by TotalTokens desc\r\n"

  kql_cost_by_model = "${local.pricing_datatable}ApiManagementGatewayLlmLog\r\n| where TimeGenerated > ago(24h)\r\n| where TotalTokens > 0 and isnotempty(DeploymentName)\r\n| summarize PromptTokens = sum(PromptTokens), CompletionTokens = sum(CompletionTokens) by DeploymentName\r\n| join kind=inner pricingData on $left.DeploymentName == $right.Model\r\n| extend EstimatedCostUSD = round((PromptTokens / 1000.0) * InputPrice + (CompletionTokens / 1000.0) * OutputPrice, 4)\r\n| project DeploymentName, EstimatedCostUSD\r\n| order by EstimatedCostUSD desc\r\n"

  kql_cost_by_subscription = "${local.subscription_names_datatable}${local.pricing_datatable}ApiManagementGatewayLlmLog\r\n| where TimeGenerated > ago(24h)\r\n| where TotalTokens > 0 and isnotempty(DeploymentName)\r\n| join kind=leftouter (\r\n    ApiManagementGatewayLogs\r\n    | where TimeGenerated > ago(24h)\r\n    | where isnotempty(ApimSubscriptionId)\r\n    | summarize ApimSubscriptionId = any(ApimSubscriptionId) by CorrelationId\r\n) on CorrelationId\r\n| extend SubscriptionId = iif(isempty(ApimSubscriptionId), \"unknown\", ApimSubscriptionId)\r\n| lookup subscriptionNames on SubscriptionId\r\n| extend Subscription = coalesce(SubscriptionName, SubscriptionId)\r\n| join kind=inner pricingData on $left.DeploymentName == $right.Model\r\n| extend EstimatedCostUSD = round((PromptTokens / 1000.0) * InputPrice + (CompletionTokens / 1000.0) * OutputPrice, 4)\r\n| summarize EstimatedCostUSD = sum(EstimatedCostUSD) by Subscription\r\n| order by EstimatedCostUSD desc\r\n"

  kql_token_over_time = "${local.subscription_names_datatable}ApiManagementGatewayLlmLog\r\n| where TimeGenerated > ago(12h)\r\n| where TotalTokens > 0 and isnotempty(DeploymentName)\r\n| join kind=leftouter (\r\n    ApiManagementGatewayLogs\r\n    | where TimeGenerated > ago(12h)\r\n    | where isnotempty(ApimSubscriptionId)\r\n    | summarize ApimSubscriptionId = any(ApimSubscriptionId) by CorrelationId\r\n) on CorrelationId\r\n| extend SubscriptionId = iif(isempty(ApimSubscriptionId), \"unknown\", ApimSubscriptionId)\r\n| lookup subscriptionNames on SubscriptionId\r\n| extend Subscription = coalesce(SubscriptionName, SubscriptionId)\r\n| summarize TotalTokens = sum(TotalTokens) by Subscription, DeploymentName, bin(TimeGenerated, 5m)\r\n| extend SeriesKey = strcat(DeploymentName, \" / \", Subscription)\r\n| project TimeGenerated, SeriesKey, TotalTokens\r\n| order by TimeGenerated asc\r\n"

  kql_rate_limit = "${local.subscription_names_datatable}ApiManagementGatewayLogs\r\n| where TimeGenerated > ago(1h)\r\n| where IsRequestSuccess == true and isnotempty(ResponseHeaders)\r\n| extend rh = parse_json(ResponseHeaders)\r\n| extend RemainingTokens = toint(rh[\"x-ratelimit-remaining-tokens\"])\r\n| where isnotnull(RemainingTokens)\r\n| extend SubscriptionId = ApimSubscriptionId\r\n| lookup subscriptionNames on SubscriptionId\r\n| extend Subscription = coalesce(SubscriptionName, SubscriptionId)\r\n| summarize AvgRemainingTokens = avg(RemainingTokens) by Subscription, bin(TimeGenerated, 1m)\r\n| order by TimeGenerated asc\r\n"

  kql_token_by_sub_stacked_by_model = "${local.subscription_names_datatable}ApiManagementGatewayLlmLog\r\n| where TimeGenerated > ago(24h)\r\n| where TotalTokens > 0 and isnotempty(DeploymentName)\r\n| join kind=leftouter (\r\n    ApiManagementGatewayLogs\r\n    | where TimeGenerated > ago(24h)\r\n    | where isnotempty(ApimSubscriptionId)\r\n    | summarize ApimSubscriptionId = any(ApimSubscriptionId) by CorrelationId\r\n) on CorrelationId\r\n| extend SubscriptionId = iif(isempty(ApimSubscriptionId), \"unknown\", ApimSubscriptionId)\r\n| lookup subscriptionNames on SubscriptionId\r\n| extend Subscription = coalesce(SubscriptionName, SubscriptionId)\r\n| summarize TotalTokens = sum(TotalTokens) by Subscription, DeploymentName\r\n| order by TotalTokens desc\r\n"

  kql_cost_by_sub_stacked_by_model = "${local.subscription_names_datatable}${local.pricing_datatable}ApiManagementGatewayLlmLog\r\n| where TimeGenerated > ago(24h)\r\n| where TotalTokens > 0 and isnotempty(DeploymentName)\r\n| join kind=leftouter (\r\n    ApiManagementGatewayLogs\r\n    | where TimeGenerated > ago(24h)\r\n    | where isnotempty(ApimSubscriptionId)\r\n    | summarize ApimSubscriptionId = any(ApimSubscriptionId) by CorrelationId\r\n) on CorrelationId\r\n| extend SubscriptionId = iif(isempty(ApimSubscriptionId), \"unknown\", ApimSubscriptionId)\r\n| lookup subscriptionNames on SubscriptionId\r\n| extend Subscription = coalesce(SubscriptionName, SubscriptionId)\r\n| join kind=inner pricingData on $left.DeploymentName == $right.Model\r\n| extend EstimatedCostUSD = round((PromptTokens / 1000.0) * InputPrice + (CompletionTokens / 1000.0) * OutputPrice, 4)\r\n| summarize EstimatedCostUSD = sum(EstimatedCostUSD) by Subscription, DeploymentName\r\n| order by EstimatedCostUSD desc\r\n"

  # ── Shorthand references ──────────────────────────────────────────────────
  workspace_id   = azurerm_log_analytics_workspace.apim_log_analytics.id
  workspace_name = azurerm_log_analytics_workspace.apim_log_analytics.name
  ai_id          = azurerm_application_insights.apim_ai_logger.id
  ai_name        = azurerm_application_insights.apim_ai_logger.name
}

# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_portal_dashboard" "ai_gateway" {
  name                = "apim-ai-gateway-dashboard-${var.app_suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  tags = {
    "hidden-title" = "APIM ❤️ AI Gateway — Load Balancing"
  }

  dashboard_properties = jsonencode({
    lenses = {
      "0" = {
        order = 0
        parts = {

          # ── Row 0 ────────────────────────────────────────────────────────

          # Tile 0: Lab image / markdown
          "0" = {
            position = { x = 0, y = 0, rowSpan = 4, colSpan = 6 }
            metadata = {
              inputs = []
              type   = "Extension/HubsExtension/PartType/MarkdownPart"
              settings = {
                content = {
                  settings = {
                    content     = "<a href=\"https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/backend-pool-load-balancing-tf2\" target=\"_blank\"><img src=\"https://raw.githubusercontent.com/Azure-Samples/AI-Gateway/refs/heads/main/images/ai-gateway.gif\" style=\"max-width:100%%;max-height:100%%\"/></a>"
                    markdownUri = null
                  }
                }
              }
            }
          }

          # Tile 1: Resource Group map
          "1" = {
            position = { x = 6, y = 0, rowSpan = 2, colSpan = 2 }
            metadata = {
              inputs = [
                { name = "resourceGroup", isOptional = true },
                { name = "id", value = azurerm_resource_group.rg.id, isOptional = true }
              ]
              type = "Extension/HubsExtension/PartType/ResourceGroupMapPinnedPart"
            }
          }

          # Tile 2: Token usage by model (bar, 24h)
          "2" = {
            position = { x = 8, y = 0, rowSpan = 4, colSpan = 7 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-token-by-model", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "P1D", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_token_by_model, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "UnstackedColumn", isOptional = true },
                { name = "PartTitle", value = "Token usage by model (24h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "DeploymentName", type = "string" }
                    yAxis       = [{ name = "TotalPromptTokens", type = "long" }, { name = "TotalCompletionTokens", type = "long" }]
                    splitBy     = []
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # ── Row 4 ────────────────────────────────────────────────────────

          # Tile 3: Token usage by subscription (donut, 24h)
          "3" = {
            position = { x = 0, y = 4, rowSpan = 4, colSpan = 5 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-token-by-sub", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "P1D", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_token_by_subscription, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "Donut", isOptional = true },
                { name = "PartTitle", value = "Token usage by subscription (24h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "Subscription", type = "string" }
                    yAxis       = [{ name = "TotalTokens", type = "long" }]
                    splitBy     = []
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # Tile 4: Estimated cost by model (bar, 24h)
          "4" = {
            position = { x = 5, y = 4, rowSpan = 4, colSpan = 5 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-cost-by-model", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "P1D", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_cost_by_model, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "UnstackedColumn", isOptional = true },
                { name = "PartTitle", value = "Estimated cost (USD) by model (24h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "DeploymentName", type = "string" }
                    yAxis       = [{ name = "EstimatedCostUSD", type = "real" }]
                    splitBy     = []
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # Tile 5: Estimated cost by subscription (bar, 24h)
          "5" = {
            position = { x = 10, y = 4, rowSpan = 4, colSpan = 5 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-cost-by-sub", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "P1D", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_cost_by_subscription, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "UnstackedColumn", isOptional = true },
                { name = "PartTitle", value = "Estimated cost (USD) by subscription (24h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "Subscription", type = "string" }
                    yAxis       = [{ name = "EstimatedCostUSD", type = "real" }]
                    splitBy     = []
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # ── Row 8 ────────────────────────────────────────────────────────

          # Tile 6: Total tokens per subscription stacked by model (24h)
          "6" = {
            position = { x = 0, y = 8, rowSpan = 4, colSpan = 7 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-token-sub-model", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "P1D", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_token_by_sub_stacked_by_model, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "StackedColumn", isOptional = true },
                { name = "PartTitle", value = "Total tokens per subscription by model (24h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "Subscription", type = "string" }
                    yAxis       = [{ name = "TotalTokens", type = "long" }]
                    splitBy     = [{ name = "DeploymentName", type = "string" }]
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # Tile 7: Cost per subscription stacked by model (24h)
          "7" = {
            position = { x = 7, y = 8, rowSpan = 4, colSpan = 8 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-cost-sub-model", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "P1D", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_cost_by_sub_stacked_by_model, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "StackedColumn", isOptional = true },
                { name = "PartTitle", value = "Estimated cost (USD) per subscription by model (24h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "Subscription", type = "string" }
                    yAxis       = [{ name = "EstimatedCostUSD", type = "real" }]
                    splitBy     = [{ name = "DeploymentName", type = "string" }]
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # ── Row 12 ───────────────────────────────────────────────────────

          # Tile 8: Token usage over time — line (12h)
          "8" = {
            position = { x = 0, y = 12, rowSpan = 4, colSpan = 9 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-token-over-time", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "PT12H", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_token_over_time, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "Line", isOptional = true },
                { name = "PartTitle", value = "Total tokens consumed over time (12h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "TimeGenerated", type = "datetime" }
                    yAxis       = [{ name = "TotalTokens", type = "long" }]
                    splitBy     = [{ name = "SeriesKey", type = "string" }]
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # Tile 9: Rate limit remaining tokens — line (1h)
          "9" = {
            position = { x = 9, y = 12, rowSpan = 4, colSpan = 6 }
            metadata = {
              inputs = [
                { name = "resourceTypeMode", isOptional = true },
                { name = "ComponentId", isOptional = true },
                { name = "Scope", value = { resourceIds = [local.workspace_id] }, isOptional = true },
                { name = "PartId", value = "tile-rate-limit", isOptional = true },
                { name = "Version", value = "2.0", isOptional = true },
                { name = "TimeRange", value = "PT1H", isOptional = true },
                { name = "DashboardId", isOptional = true },
                { name = "DraftRequestParameters", isOptional = true },
                { name = "Query", value = local.kql_rate_limit, isOptional = true },
                { name = "ControlType", value = "FrameControlChart", isOptional = true },
                { name = "SpecificChart", value = "Line", isOptional = true },
                { name = "PartTitle", value = "Remaining tokens per subscription (1h)", isOptional = true },
                { name = "PartSubTitle", value = local.workspace_name, isOptional = true },
                {
                  name  = "Dimensions"
                  value = {
                    xAxis       = { name = "TimeGenerated", type = "datetime" }
                    yAxis       = [{ name = "AvgRemainingTokens", type = "real" }]
                    splitBy     = [{ name = "Subscription", type = "string" }]
                    aggregation = "Sum"
                  }
                  isOptional = true
                },
                { name = "LegendOptions", value = { isEnabled = true, position = "Bottom" }, isOptional = true },
                { name = "IsQueryContainTimeRange", value = false, isOptional = true }
              ]
              type     = "Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart"
              settings = { content = {} }
            }
          }

          # ── Row 16 ───────────────────────────────────────────────────────

          # Tile 10: Server requests (App Insights metric)
          "10" = {
            position = { x = 0, y = 16, rowSpan = 3, colSpan = 5 }
            metadata = {
              inputs = [
                {
                  name = "options"
                  value = {
                    chart = {
                      metrics = [{
                        resourceMetadata   = { id = local.ai_id }
                        name               = "requests/count"
                        aggregationType    = 7
                        namespace          = "microsoft.insights/components"
                        metricVisualization = {
                          displayName         = "Server requests"
                          resourceDisplayName = local.ai_name
                          color               = "#0078D4"
                        }
                      }]
                      title     = "Server requests"
                      titleKind = 2
                      visualization = { chartType = 3 }
                      openBladeOnClick = {
                        openBlade        = true
                        destinationBlade = {
                          bladeName     = "ResourceMenuBlade"
                          parameters    = { id = local.ai_id, menuid = "performance" }
                          extensionName = "HubsExtension"
                          options       = { parameters = { id = local.ai_id, menuid = "performance" } }
                        }
                      }
                    }
                  }
                  isOptional = true
                },
                { name = "sharedTimeRange", isOptional = true }
              ]
              type     = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = { content = {} }
            }
          }

          # Tile 11: Server response time (App Insights metric)
          "11" = {
            position = { x = 5, y = 16, rowSpan = 3, colSpan = 5 }
            metadata = {
              inputs = [
                {
                  name = "options"
                  value = {
                    chart = {
                      metrics = [{
                        resourceMetadata   = { id = local.ai_id }
                        name               = "requests/duration"
                        aggregationType    = 4
                        namespace          = "microsoft.insights/components"
                        metricVisualization = {
                          displayName         = "Server response time"
                          resourceDisplayName = local.ai_name
                          color               = "#0078D4"
                        }
                      }]
                      title     = "Server response time"
                      titleKind = 2
                      visualization = { chartType = 2 }
                      openBladeOnClick = {
                        openBlade        = true
                        destinationBlade = {
                          bladeName     = "ResourceMenuBlade"
                          parameters    = { id = local.ai_id, menuid = "performance" }
                          extensionName = "HubsExtension"
                          options       = { parameters = { id = local.ai_id, menuid = "performance" } }
                        }
                      }
                    }
                  }
                  isOptional = true
                },
                { name = "sharedTimeRange", isOptional = true }
              ]
              type     = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = { content = {} }
            }
          }

          # Tile 12: Failed requests (App Insights metric)
          "12" = {
            position = { x = 10, y = 16, rowSpan = 3, colSpan = 5 }
            metadata = {
              inputs = [
                {
                  name = "options"
                  value = {
                    chart = {
                      metrics = [{
                        resourceMetadata   = { id = local.ai_id }
                        name               = "requests/failed"
                        aggregationType    = 7
                        namespace          = "microsoft.insights/components"
                        metricVisualization = {
                          displayName         = "Failed requests"
                          resourceDisplayName = local.ai_name
                          color               = "#EC008C"
                        }
                      }]
                      title     = "Failed requests"
                      titleKind = 2
                      visualization = { chartType = 3 }
                      openBladeOnClick = {
                        openBlade        = true
                        destinationBlade = {
                          bladeName     = "ResourceMenuBlade"
                          parameters    = { id = local.ai_id, menuid = "failures" }
                          extensionName = "HubsExtension"
                          options       = { parameters = { id = local.ai_id, menuid = "failures" } }
                        }
                      }
                    }
                  }
                  isOptional = true
                },
                { name = "sharedTimeRange", isOptional = true }
              ]
              type     = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = { content = {} }
            }
          }

        } # end parts
      }   # end lens 0
    }     # end lenses

    metadata = {
      model = {
        timeRange = {
          value = {
            relative = {
              duration = 24
              timeUnit = 1
            }
          }
          type = "MsPortalFx.Composition.Configuration.ValueTypes.TimeRange"
        }
        filterLocale = { value = "en-us" }
        filters = {
          value = {
            MsPortalFx_TimeRange = {
              model = {
                format      = "utc"
                granularity = "30m"
                relative    = "24h"
              }
              displayCache = {
                name  = "UTC Time"
                value = "Past 24 hours"
              }
            }
          }
        }
      }
    }
  })
}

# ── Output ───────────────────────────────────────────────────────────────────
output "dashboard_id" {
  value = azurerm_portal_dashboard.ai_gateway.id
}
