###############################################################################
# provider.tf
# Terraform + AzureRM provider configuration.
#
# Run from the folder that contains this file:
#   cd terraform
#   terraform init
###############################################################################

terraform {
  # Terraform CLI 1.5 or newer is required.
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"

  # `features` block is mandatory in AzureRM provider v4.
  features {
    resource_group {
      # Protects a Resource Group from accidental `terraform destroy` while it
      # still contains resources. You can still delete it explicitly with
      # `terraform destroy -target=azurerm_resource_group.main`.
      prevent_deletion_if_contains_resources = true
    }
  }

  # ---------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------
  # Two supported ways to authenticate (you only need ONE):
  #
  #  A) Azure CLI (recommended for this project):
  #       az login
  #       az account set --subscription "<Subscription Name>"
  #     Leave `subscription_id` as null (the default). The provider then
  #     uses the subscription from your active `az` login context.
  #
  #  B) Service Principal (recommended for CI / repeatable runs):
  #       export ARM_SUBSCRIPTION_ID="..."
  #       export ARM_TENANT_ID="..."
  #       export ARM_CLIENT_ID="..."
  #       export ARM_CLIENT_SECRET="..."
  #     Leave the variables as null and let the environment variables
  #     drive the provider.
  #
  # NOTE: `az login` tokens live in %USERPROFILE%\.azure. Never commit that
  #       folder and never paste secrets into a .tfvars file that is tracked
  #       by Git.
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
