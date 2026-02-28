variable "subscription_id" {
  type        = string
  default     = "00000000-0000-0000-0000-000000000000"
}

variable "app_suffix" {
  type        = string
  default     = "eq9wMc4L"
}

variable "resource_group_name" {
  type        = string
  default     = "lab-backend-pool-load-balancing-terraform"
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
  default = {
    openai-uks = {
      name     = "meraki-test-001",
      location = "eastus",
      priority = 1,
      weight   = 100
    },
    openai-swc = {
      name     = "openai2",
      location = "swedencentral",
      priority = 2,
      weight   = 50
    },
    openai-frc = {
      name     = "openai3",
      location = "francecentral",
      priority = 2,
      weight   = 50
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

# variable "openai_deployment_name" {
#   type        = string
#   default     = "gpt-4o"
# }

# variable "embedding_openai_deployment_name" {
#   type        = string
#   default     = "embedding"
# }

variable "openai_sku" {
  type        = string
  default     = "S0"
}

# variable "openai_model_name" {
#   type        = string
#   default     = "gpt-4o"
# }

# variable "openai_model_name_embedding" {
#   type        = string
#   default     = "text-embedding-3-small"
# }

# variable "openai_model_version" {
#   type        = string
#   default     = "2024-08-06"
# }

# variable "openai_model_version_embedding" {
#   type        = string
#   default     = "1"
# }

# variable "openai_model_capacity" {
#   type        = number
#   default     = 8
# }

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

# New variable for auto scaling configuration
variable "enable_apim_autoscale" {
  type        = bool
  default     = true
  description = "Enable auto scaling for APIM"
}

variable "apim_autoscale_min_capacity" {
  type        = number
  default     = 1
  description = "Minimum number of scale units for auto scaling"
}

variable "apim_autoscale_max_capacity" {
  type        = number
  default     = 10
  description = "Maximum number of scale units for auto scaling"
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
  description = "Map of tenant subscriptions to create in APIM. Key = tenant slug, value = display info."
  type = map(object({
    display_name = string
    tenant_id    = string            # Customer tenant / org identifier
    state        = optional(string, "active")  # active | suspended | cancelled
  }))
  default = {}
}

