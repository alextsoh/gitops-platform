terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# 1. Resource Group
resource "azurerm_resource_group" "aks_rg" {
  name     = "aks-cluster_group"
  location = "Sweden Central"
}

# 2. Network (Required for Azure CNI Overlay)
resource "azurerm_virtual_network" "vnet" {
  name                = "aks-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
}

resource "azurerm_subnet" "nodes" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.aks_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 3. AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-cluster"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  dns_prefix          = "aks-cluster-dns"
  kubernetes_version  = "1.33.6"
  
  # Custom Infrastructure RG Name
  node_resource_group = "MC_aks-cluster_group_aks-cluster_swedencentral"

  # Identity and Access
  identity { type = "SystemAssigned" }
  local_account_disabled = false

  # Node Auto-provisioning (NAP) - Fixed for Terraform
  node_provisioning_profile {
    mode = "Auto"
  }

  default_node_pool {
    name           = "nodepool1"
    node_count     = 1
    vm_size        = "Standard_D2ps_v6" # ARM64
    vnet_subnet_id = azurerm_subnet.nodes.id
    zones = null
  }

  # Networking: CNI Overlay + Cilium
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium" # Correct argument name
    load_balancer_sku   = "standard"
  }

  # Advanced Features
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Upgrade Settings
  automatic_upgrade_channel = "node-image"
  node_os_upgrade_channel   = "NodeImage"

  # Key Vault Secrets Provider
  key_vault_secrets_provider {
    secret_rotation_enabled = true # Automatically syncs secret changes
  }

}