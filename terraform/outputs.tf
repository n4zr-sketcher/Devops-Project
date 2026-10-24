###############################################################################
# outputs.tf
# Terraform prints these after `terraform apply` (and after `terraform output`).
# They are the bridge between Terraform and the Jenkins pipeline: Jenkins reads
# the public IP from here instead of a hard-coded value.
###############################################################################

output "resource_group_name" {
  description = "Name of the Resource Group that was created."
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region the resources were created in."
  value       = azurerm_resource_group.main.location
}

output "public_ip_address" {
  description = "Public IPv4 address of the application VM (this is your website URL)."
  value       = azurerm_public_ip.main.ip_address
}

output "http_url" {
  description = "Full URL of the deployed website."
  value       = "http://${azurerm_public_ip.main.ip_address}"
}

output "health_url" {
  description = "Nginx health-check endpoint used by the Jenkins Verify stage."
  value       = "http://${azurerm_public_ip.main.ip_address}/health"
}

output "ssh_command" {
  description = "Command you can run locally to log in to the VM."
  value       = "ssh -i ~/.ssh/azure_cicd_vm ${var.admin_username}@${azurerm_public_ip.main.ip_address}"
}

output "vm_name" {
  description = "Name of the virtual machine."
  value       = azurerm_linux_virtual_machine.main.name
}

output "vm_id" {
  description = "Resource ID of the virtual machine."
  value       = azurerm_linux_virtual_machine.main.id
}

output "web_root" {
  description = "Directory on the VM that Nginx serves (a symlink to the active release)."
  value       = var.remote_app_dir
}

output "releases_dir" {
  description = "Directory on the VM holding the immutable release folders."
  value       = var.remote_releases_dir
}

output "next_steps" {
  description = "Helpful summary printed after `terraform apply`."
  value       = <<-EOT
    ============================================================
     Deployment of the application is the NEXT step
    ============================================================
     Website : http://${azurerm_public_ip.main.ip_address}
     Health  : http://${azurerm_public_ip.main.ip_address}/health
     SSH     : ssh -i ~/.ssh/azure_cicd_vm ${var.admin_username}@${azurerm_public_ip.main.ip_address}

     The VM currently shows a placeholder page.
     Jenkins will overwrite it with the real site on the first
     successful pipeline run (Phase 5).

     ALWAYS destroy the cloud resources when you are finished:
       cd terraform
       terraform destroy
    ============================================================
  EOT
}
