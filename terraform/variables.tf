###############################################################################
# variables.tf
# Every setting that you might want to change lives here.
#
# Values are supplied via:
#   terraform.tfvars          (real values - GIT IGNORED, never committed)
#   terraform.tfvars.example  (template - safe to commit)
#   TF_VAR_<NAME> environment variables
###############################################################################

# -----------------------------------------------------------------------------
# Azure account / subscription
# -----------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID. Leave as null to use the active `az login` context."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Azure AD tenant ID. Leave as null to use the active `az login` context."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Naming and location
# -----------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Name of the Azure Resource Group that holds every resource."
  type        = string
  default     = "rg-devops-cicd"

  validation {
    condition     = length(var.resource_group_name) > 0 && length(var.resource_group_name) <= 90
    error_message = "resource_group_name must be between 1 and 90 characters."
  }
}

variable "location" {
  description = "Azure region where all resources are created."
  type        = string
  default     = "eastus"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "location must be a lowercase Azure region name, for example eastus or westus."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource (helps with cost tracking)."
  type        = map(string)
  default = {
    Project     = "devops-cicd-terraform-jenkins"
    ManagedBy   = "terraform"
    Environment = "college-demo"
    Owner       = "student"
  }
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "vnet_name" {
  description = "Name of the Virtual Network."
  type        = string
  default     = "vnet-devops-cicd"
}

variable "vnet_address_space" {
  description = "Address space (CIDR) for the Virtual Network."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_name" {
  description = "Name of the subnet that hosts the application VM."
  type        = string
  default     = "snet-app"
}

variable "subnet_address_prefix" {
  description = "Address prefix (CIDR) for the application subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "nsg_name" {
  description = "Name of the Network Security Group."
  type        = string
  default     = "nsg-devops-cicd"
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    The ONLY public IP (or CIDR block) allowed to reach SSH (TCP 22) on the VM.
    Use your own public IP in CIDR form, e.g. "203.0.113.42/32".
    Run `Invoke-RestMethod https://api.ipify.org` (PowerShell) or
    `curl https://api.ipify.org` (Linux/macOS) to find your current IP.
  EOT
  type        = string
  default     = "203.0.113.42/32"

  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr must be a valid IPv4 CIDR, for example 203.0.113.42/32."
  }
}

variable "public_ip_name" {
  description = "Name of the Public IP resource attached to the VM."
  type        = string
  default     = "pip-devops-cicd"
}

variable "nic_name" {
  description = "Name of the Network Interface."
  type        = string
  default     = "nic-devops-cicd"
}

# -----------------------------------------------------------------------------
# Virtual Machine
# -----------------------------------------------------------------------------

variable "vm_name" {
  description = "Name of the Linux Virtual Machine."
  type        = string
  default     = "vm-devops-cicd"
}

variable "vm_computer_name" {
  description = "Windows-style host name of the VM (max 15 characters, lowercase letters/digits/hyphens)."
  type        = string
  default     = "devops-cicd-vm"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,15}$", var.vm_computer_name))
    error_message = "vm_computer_name must be 1-15 characters of lowercase letters, digits or hyphens."
  }
}

variable "vm_size" {
  description = <<-EOT
    Azure VM size. Default Standard_B1ls is the cheapest Linux VM and is more
    than enough for Nginx serving static files. Use Standard_B2s if you also
    want to run heavier workloads on the same machine.
  EOT
  type        = string
  default     = "Standard_B1ls"
}

variable "admin_username" {
  description = "Local administrator (SSH) user name created on the VM."
  type        = string
  default     = "azureuser"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{2,31}$", var.admin_username))
    error_message = "admin_username must be 3-32 characters, lowercase, starting with a letter or underscore."
  }
}

variable "ssh_public_key" {
  description = <<-EOT
    The PUBLIC half of the SSH key pair that Jenkins will use to deploy.
    Generate with:
      ssh-keygen -t ed25519 -f ~/.ssh/azure_cicd_vm -N ""
    Paste the contents of  ~/.ssh/azure_cicd_vm.pub  here.
    The PRIVATE key stays on your machine (and in Jenkins credentials) and
    must never be committed to Git.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ssh-(rsa|ed25519) ", var.ssh_public_key))
    error_message = "ssh_public_key must look like 'ssh-ed25519 AAAA... comment' (one single line)."
  }
}

variable "os_disk_size_gb" {
  description = "Size of the VM OS disk in GiB (minimum 30 for Standard_LRS)."
  type        = number
  default     = 30

  validation {
    condition     = var.os_disk_size_gb >= 30
    error_message = "os_disk_size_gb must be at least 30 for Standard_LRS disks."
  }
}

variable "vm_image_publisher" {
  description = "Publisher of the VM image."
  type        = string
  default     = "Canonical"
}

variable "vm_image_offer" {
  description = "Offer of the VM image (Ubuntu Server 22.04 LTS)."
  type        = string
  default     = "0001-com-ubuntu-server-jammy"
}

variable "vm_image_sku" {
  description = "SKU of the VM image."
  type        = string
  default     = "22_04-lts"
}

variable "vm_image_version" {
  description = "Version of the VM image. 'latest' always picks the newest patch."
  type        = string
  default     = "latest"
}

# -----------------------------------------------------------------------------
# Application deployment targets (used by cloud-init + scripts/deploy.sh)
# -----------------------------------------------------------------------------

variable "remote_app_dir" {
  description = "Absolute path on the VM that Nginx serves. A symlink to the active release."
  type        = string
  default     = "/var/www/app"
}

variable "remote_releases_dir" {
  description = "Absolute path on the VM where immutable release folders are stored."
  type        = string
  default     = "/var/www/releases"
}

variable "nginx_site_name" {
  description = "Name of the Nginx server-block file inside /etc/nginx/sites-available."
  type        = string
  default     = "app"
}

variable "placeholder_title" {
  description = "Title shown on the placeholder page served before the first CI/CD deployment."
  type        = string
  default     = "Terraform bootstrap complete"
}
