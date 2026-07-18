locals {
  user_data = templatefile("${path.module}/../../provisioning/cloud-init.yaml", {
    username            = var.username
    ssh_public_key      = var.ssh_public_key
    install_docker      = var.install_docker
    install_codex       = var.install_codex
    install_claude      = var.install_claude
    install_opencode    = var.install_opencode
    install_antigravity = var.install_antigravity
    install_browser     = var.install_browser
    workspace_device    = ""
    install_base        = file("${path.module}/../../provisioning/install-base.sh")
    install_agents      = file("${path.module}/../../provisioning/install-agents.sh")
    browser             = file("${path.module}/../../provisioning/install-browser.sh")
    install_shell       = file("${path.module}/../../provisioning/install-shell.sh")

    zshrc       = file("${path.module}/../../provisioning/zshrc")
    motd        = file("${path.module}/../../provisioning/motd.sh")
    tmux_conf   = file("${path.module}/../../provisioning/tmux.conf")
    tmux_status = file("${path.module}/../../provisioning/tmux-status.sh")
    osc7        = file("${path.module}/../../provisioning/osc7.sh")
  })
}

resource "azurerm_resource_group" "this" {
  name     = var.name
  location = var.location
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.80.0.0/16"]
}

resource "azurerm_subnet" "this" {
  name                 = "${var.name}-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.80.1.0/24"]
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.name}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "this" {
  name                = "${var.name}-ip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "this" {
  name                = "${var.name}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                  = var.name
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  size                  = var.vm_size
  admin_username        = var.username
  network_interface_ids = [azurerm_network_interface.this.id]
  custom_data           = base64encode(local.user_data)

  admin_ssh_key {
    username   = var.username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
