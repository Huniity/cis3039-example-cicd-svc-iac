output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "products_url" {
  value = "https://${azurerm_function_app_flex_consumption.this.default_hostname}/api/products"
}

output "application_insights_name" {
  value = azurerm_application_insights.this.name
}
