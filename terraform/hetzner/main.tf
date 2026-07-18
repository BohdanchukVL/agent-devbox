locals {
  use_volume = var.disk_size > 0

  user_data = templatefile("${path.module}/../../provisioning/cloud-init.yaml", {
    username            = var.username
    ssh_public_key      = var.ssh_public_key
    install_docker      = var.install_docker
    install_codex       = var.install_codex
    install_claude      = var.install_claude
    install_opencode    = var.install_opencode
    install_antigravity = var.install_antigravity
    install_browser     = var.install_browser
    workspace_device    = local.use_volume ? "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.workspace[0].id}" : ""
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

resource "hcloud_ssh_key" "this" {
  name       = "${var.name}-key"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "this" {
  name = "${var.name}-fw"

  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "ICMP"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

# /workspace lives on its own volume so data survives server rebuilds
# (destroy still removes it — this is a disposable devbox, not a backup).
resource "hcloud_volume" "workspace" {
  count    = local.use_volume ? 1 : 0
  name     = "${var.name}-workspace"
  size     = var.disk_size
  location = var.location
}

resource "hcloud_server" "this" {
  name         = var.name
  server_type  = var.server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = [hcloud_ssh_key.this.id]
  firewall_ids = [hcloud_firewall.this.id]
  user_data    = local.user_data
}

resource "hcloud_volume_attachment" "workspace" {
  count     = local.use_volume ? 1 : 0
  volume_id = hcloud_volume.workspace[0].id
  server_id = hcloud_server.this.id
}
