locals {
  ssh_cidrs = var.ssh_allowed_cidrs != null ? var.ssh_allowed_cidrs : (
    var.tailscale_authkey != "" ? [] : ["*"]
  )

  user_data = templatefile("${path.module}/../../provisioning/cloud-init.yaml", {
    username            = var.username
    ssh_public_key      = var.ssh_public_key
    install_docker      = var.install_docker
    install_codex       = var.install_codex
    install_claude      = var.install_claude
    install_opencode    = var.install_opencode
    install_antigravity = var.install_antigravity
    install_browser     = var.install_browser
    tailscale_authkey   = var.tailscale_authkey
    workspace_device    = ""
    bootstrap_script    = file("${path.module}/../../provisioning/bootstrap.sh")
    git_repo            = var.git_repo
    git_ref             = var.git_ref
    git_token           = var.git_token
    git_sha256          = var.git_sha256
    tarball_url         = var.tarball_url
    web_token           = var.web_token
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

  dynamic "security_rule" {
    for_each = length(local.ssh_cidrs) > 0 ? [1] : []
    content {
      name                       = "SSH"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = length(local.ssh_cidrs) == 1 && local.ssh_cidrs[0] == "*" ? "*" : null
      source_address_prefixes    = length(local.ssh_cidrs) > 0 && !(length(local.ssh_cidrs) == 1 && local.ssh_cidrs[0] == "*") ? local.ssh_cidrs : null
      destination_address_prefix = "*"
    }
  }

  dynamic "security_rule" {
    for_each = var.tailscale_authkey != "" ? [1] : []
    content {
      name                       = "Tailscale-WireGuard"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Udp"
      source_port_range          = "*"
      destination_port_range     = "41641"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
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

resource "terraform_data" "payload" {
  input = join(":", [
    var.git_ref, var.install_docker, var.install_codex, var.install_claude,
    var.install_opencode, var.install_antigravity, var.install_browser, var.username,
    sha256(var.ssh_public_key), sha256(var.tailscale_authkey), sha256(var.web_token),
  ])
}

resource "azurerm_linux_virtual_machine" "this" {
  name                  = var.name
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  size                  = var.vm_size
  admin_username        = var.username
  network_interface_ids = [azurerm_network_interface.this.id]
  custom_data           = base64encode(local.user_data)

  lifecycle {
    ignore_changes       = [custom_data]
    replace_triggered_by = [terraform_data.payload]
  }

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
