variable "resource_group_name" {
  description = "Shared resource group name for AKS clusters"
  type        = string
}

variable "location" {
  description = "Azure region for the resource group and AKS clusters"
  type        = string
}

variable "enable_oidc" {
  description = "Enable AKS OIDC issuer"
  type        = bool
  default     = true
}

variable "enable_workload_identity" {
  description = "Enable AKS workload identity (recommended with OIDC)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "clusters" {
  description = "Map of AKS cluster definitions keyed by cluster name"
  type = map(object({
    dns_prefix         = string
    node_count         = number
    vm_size            = string
    kubernetes_version = optional(string)
    tags               = optional(map(string))
  }))
}
