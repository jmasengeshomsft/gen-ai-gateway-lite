variable "subscription_id" {
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
}

variable "app_suffix" {
  description = "Short unique string appended to all resource names (e.g. 'abc123')"
  type        = string
}

variable "resource_group_name" {
  description = "Base name for the resource group (app_suffix is appended)"
  type        = string
  default     = "ai-gateway-lite"
}

variable "resource_group_location" {
  type        = string
  default     = "eastus"
}

variable "openai_backend_pool_name" {
  type        = string
  default     = "openai-backend-pool"
}

variable "openai_config" {
  description = "Map of Azure AI Services (OpenAI) backends. Each entry becomes a backend in the APIM load-balanced pool."
  type = map(object({
    name     = string
    location = string
    priority = number
    weight   = number
  }))
  default = {
    openai-eus = {
      name     = "ai-services-eastus"
      location = "eastus"
      priority = 1
      weight   = 100
    }
  }
}

variable "openai_deployments" {
  description = "Which deployments to create per AI service. Optional input_price/output_price (per 1K tokens, USD) enable cost estimation in the dashboard."
  type = map(object({
    deployment_name = string
    model_name      = string
    model_version   = string
    model_capacity  = number
    input_price     = optional(number)
    output_price    = optional(number)
  }))
  default = {
    gpt = {
      deployment_name = "gpt-4o"
      model_name      = "gpt-4o"
      model_version   = "2024-08-06"
      model_capacity  = 8
      input_price     = 0.0025
      output_price    = 0.01
    }
    embedding = {
      deployment_name = "embedding"
      model_name      = "text-embedding-3-small"
      model_version   = "1"
      model_capacity  = 8
      input_price     = 0.00002
      output_price    = 0.00002
    }
  }
}

variable "openai_sku" {
  type        = string
  default     = "S0"
}

variable "openai_api_spec_url" {
  type        = string
  default     = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
}

variable "apim_resource_name" {
  type        = string
  default     = "apim"
}

variable "apim_resource_location" {
  type        = string
  default     = "eastus" # APIM SKU StandardV2 is not yet supported in the region Sweden Central
}

variable "apim_sku" {
  type        = string
  default     = "StandardV2"  # Changed from BasicV2 to enable auto scaling
  description = "The SKU of the API Management service. StandardV2 or higher required for auto scaling."
}

variable "apim_sku_capacity" {
  type        = number
  default     = 1
  description = "The initial capacity (scale units) of the API Management service"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Monitoring & Alerting Configuration
# ═══════════════════════════════════════════════════════════════════════════════
variable "monitoring_alerting" {
  description = "APIM monitoring and alerting configuration. When enabled, alert_emails is required."
  type = object({
    enabled              = optional(bool, false)
    alert_emails         = optional(list(string), [])    # Required when enabled=true
    alert_severity       = optional(number, 2)           # 0=Critical, 1=Error, 2=Warning, 3=Info, 4=Verbose
    error_4xx_threshold  = optional(number, 10)          # Alert if > N 4xx errors in 5 min
    capacity_threshold   = optional(number, 70)          # Alert if capacity >= N%
    latency_threshold_ms = optional(number, 4000)        # Alert if avg latency > N ms
  })
  default = {
    enabled = false
  }

  validation {
    condition     = !var.monitoring_alerting.enabled || length(var.monitoring_alerting.alert_emails) > 0
    error_message = "alert_emails must contain at least one email address when monitoring is enabled."
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Auto-Scaling Configuration
# ═══════════════════════════════════════════════════════════════════════════════
variable "autoscale" {
  description = "APIM auto-scaling configuration (requires StandardV2 or higher SKU)"
  type = object({
    enabled             = optional(bool, false)
    min_capacity        = optional(number, 1)
    max_capacity        = optional(number, 3)
    scale_out_threshold = optional(number, 70)           # Scale out when capacity > N%
    scale_in_threshold  = optional(number, 30)           # Scale in when capacity < N%
    cooldown_period     = optional(string, "PT5M")       # Cooldown between scaling actions
  })
  default = {
    enabled = false
  }
}

variable "openai_api_version" {
  type        = string
  default     = "2024-10-21"
}

variable "vnet_name" {
  description = "Name of the virtual network"
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = string
}

variable "subnet_apim_address_space" {
  description = "Address space for the APIM subnet"
  type        = string
}

variable "subnet_private_endpoints_address_space" {
  description = "Address space for the private endpoints subnet"
  type        = string
}

variable "workspace_openai_dimension" {
  description = "The dimension of the OpenAI workspace"
  type        = string
  default     = "openai"
}

# ── APIM Tenant Subscriptions ─────────────────────────────────────────────────
variable "apim_tenants" {
  description = "Map of tenant subscriptions to create in APIM. Key = tenant slug, value = display info + optional quota overrides."
  type = map(object({
    display_name      = string
    tenant_id         = string                       # Customer tenant / org identifier
    state             = optional(string, "active")   # active | suspended | cancelled
    tokens_per_minute  = optional(number)             # Per-tenant TPM override (null = use default)
    token_quota        = optional(number)             # Per-tenant token quota override (null = use default)
    token_quota_period = optional(string)             # Quota reset period: Hourly|Daily|Weekly|Monthly|Yearly (null = use default)
  }))
  default = {}
}

# ── Default token limits (apply to lab subscription and any tenant without overrides) ──
variable "default_tokens_per_minute" {
  description = "Default tokens-per-minute rate limit for subscriptions without a per-tenant override."
  type        = number
  default     = 10000
}

variable "default_token_quota" {
  description = "Default token quota for subscriptions without a per-tenant override."
  type        = number
  default     = 500000
}

variable "default_token_quota_period" {
  description = "Default quota reset period: Hourly, Daily, Weekly, Monthly, or Yearly."
  type        = string
  default     = "Monthly"

  validation {
    condition     = contains(["Hourly", "Daily", "Weekly", "Monthly", "Yearly"], var.default_token_quota_period)
    error_message = "Must be one of: Hourly, Daily, Weekly, Monthly, Yearly."
  }
}

