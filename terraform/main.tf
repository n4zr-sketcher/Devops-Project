###############################################################################
# main.tf
# All Azure resources for the "Automated Deployment of a Web Application using
# CI/CD, Terraform, Azure and Jenkins" project.
#
# Resource creation order (Terraform figures this out from the dependencies):
#   Resource Group
#     -> Virtual Network -> Subnet
#     -> Network Security Group -> NSG/Subnet association
#     -> Public IP -> Network Interface
#     -> Linux Virtual Machine (cloud-init installs Nginx)
###############################################################################

# -----------------------------------------------------------------------------
# 1. Resource Group - the container that holds every other resource
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# -----------------------------------------------------------------------------
# 2. Virtual Network
# -----------------------------------------------------------------------------
# NOTE: the subnet is created as a separate `azurerm_subnet` resource (section 3)
# instead of an inline `subnet {}` block. Defining it in both places makes
# Terraform fight with itself over the same subnet.
resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# 3. Subnet
# -----------------------------------------------------------------------------
resource "azurerm_subnet" "app" {
  name                 = var.subnet_name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_address_prefix]
}

# -----------------------------------------------------------------------------
# 4. Network Security Group + security rules
# -----------------------------------------------------------------------------
# Rule priorities must be unique and lower numbers are evaluated first.
#   100  Allow SSH   from ONE allowed IP only  (Jenkins deployment channel)
#   110  Allow HTTP  from the whole internet   (the public website)
#   4096 Deny  SSH   from every other source   (explicit defence in depth)
#
# Everything else is blocked by the NSG default rules
# (AllowVnetInBound / AllowAzureLoadBalancerInBound / DenyAllInBound).
resource "azurerm_network_security_group" "main" {
  name                = var.nsg_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-SSH-From-Allowed-CIDR"
    description                = "SSH used by the Jenkins pipeline to deploy the application."
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTP-From-Internet"
    description                = "Public website served by Nginx on port 80."
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "0.0.0.0/0"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-SSH-From-Everywhere-Else"
    description                = "Explicit deny for SSH from any source that is not the allowed CIDR."
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# The NSG is bound to the subnet (not to the VM) so it protects every future
# resource placed in that subnet as well.
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# -----------------------------------------------------------------------------
# 5. Public IP address
# -----------------------------------------------------------------------------
# Standard SKU + Static allocation gives us a stable address that never
# changes, which matters because:
#   * the NSG SSH rule and the Jenkins environment variable point at it
#   * a Standard SKU IP is the secure default in Azure
resource "azurerm_public_ip" "main" {
  name                = var.public_ip_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version          = "IPv4"
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# 6. Network Interface
# -----------------------------------------------------------------------------
# The NIC joins the subnet, the public IP and the VM together.
resource "azurerm_network_interface" "main" {
  name                = var.nic_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "app-ipconfig"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }
}

# -----------------------------------------------------------------------------
# 7. Ubuntu Linux Virtual Machine
# -----------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "main" {
  name                = var.vm_name
  computer_name       = var.vm_computer_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  # Key-based SSH only - no password is ever set on the machine.
  disable_password_authentication = true

  # NOTE: in AzureRM provider v4 the old `ssh_keys` block was renamed to
  # `admin_ssh_key`. The provider writes it to /home/<username>/.ssh/authorized_keys.
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.main.id]

  os_disk {
    name                 = "${var.vm_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.vm_image_publisher
    offer     = var.vm_image_offer
    sku       = var.vm_image_sku
    version   = var.vm_image_version
  }

  # `custom_data` on an Azure Linux VM IS cloud-init. It runs once, as the
  # admin user, the first time the machine boots. This is how Nginx gets
  # installed and configured with zero manual SSH steps.
  #
  # The provider expects the value to be BASE64 ENCODED, which is exactly what
  # base64encode() produces.
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yml.tftpl", {
    admin_username    = var.admin_username
    app_dir           = var.remote_app_dir
    releases_dir      = var.remote_releases_dir
    nginx_site        = var.nginx_site_name
    placeholder_title = var.placeholder_title
  }))

  # Enables the free platform-managed boot diagnostics (serial console log).
  boot_diagnostics {}
}
