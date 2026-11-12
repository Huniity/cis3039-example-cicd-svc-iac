# Keeps the globally unique storage account and Function App names from
# clashing. Stored in state, so it stays the same across applies.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  # Follows our naming convention, e.g. shopping-lab-x7k2qm-rg.
  name_prefix = "${var.project}-${var.environment}-${random_string.suffix.result}"

  # Storage account names allow only lowercase letters and digits, 3-24 characters.
  storage_account_name = "${replace(local.name_prefix, "-", "")}st"
}

# 1. Resource group (az group create)
resource "azurerm_resource_group" "this" {
  name     = "${local.name_prefix}-rg"
  location = var.location
}

# 2. Storage account required by Azure Functions (az storage account create --sku Standard_LRS)
resource "azurerm_storage_account" "func" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  lifecycle {
    precondition {
      condition     = length(local.storage_account_name) <= 24
      error_message = "project + environment are too long: the storage account name '${local.storage_account_name}' exceeds 24 characters."
    }
  }
}

resource "azurerm_storage_container" "function_deployment" {
  name                  = "function-deployment"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

# `az functionapp create` adds this implicitly, named after the Function App.
resource "azurerm_application_insights" "this" {
  name                = "${local.name_prefix}-func"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  application_type    = "web"

  # Azure auto-assigns a workspace; ignore it to avoid perpetual diffs.
  lifecycle {
    ignore_changes = [workspace_id]
  }
}

# 3. Flex Consumption plan (FC1)
resource "azurerm_service_plan" "this" {
  name                = "${local.name_prefix}-plan"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

# Flex Consumption Function App (Linux)
resource "azurerm_function_app_flex_consumption" "this" {
  name                = "${local.name_prefix}-func"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.this.id
  https_only          = true

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.func.primary_blob_endpoint}${azurerm_storage_container.function_deployment.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.func.primary_access_key

  runtime_name           = "node"
  runtime_version        = var.node_version
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  app_settings = var.product_updated_base_url == "" ? {} : {
    PRODUCT_UPDATED_BASE_URL = var.product_updated_base_url
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string

    dynamic "cors" {
      for_each = length(var.cors_allowed_origins) > 0 ? [1] : []

      content {
        allowed_origins = var.cors_allowed_origins
      }
    }
  }

}
