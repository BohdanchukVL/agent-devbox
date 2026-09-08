locals {
  use_volume = var.disk_size > 0

  ssh_cidrs = var.ssh_allowed_cidrs != null ? var.ssh_allowed_cidrs : (
    var.tailscale_authkey != "" ? [] : ["0.0.0.0/0", "::/0"]
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
    workspace_device    = local.use_volume ? "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.workspace[0].id}" : ""
    bootstrap_script    = file("${path.module}/../../provisioning/bootstrap.sh")
    git_repo            = var.git_repo
    git_ref             = var.git_ref
    git_token           = var.git_token
    git_sha256          = var.git_sha256
    tarball_url         = var.tarball_url
    web_token           = var.web_token
  })
}

resource "hcloud_ssh_key" "this" {
  name       = "${var.name}-key"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "this" {
  name = "${var.name}-fw"

  dynamic "rule" {
    for_each = length(local.ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH"
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = local.ssh_cidrs
    }
  }

  rule {
    description = "Tailscale WireGuard"
    direction   = "in"
    protocol    = "udp"
    port        = "41641"
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

resource "terraform_data" "payload" {
  input = join(":", [
    var.git_ref, var.server_type, var.install_docker, var.install_codex, var.install_claude,
    var.install_opencode, var.install_antigravity, var.install_browser, var.username,
    sha256(var.ssh_public_key), sha256(var.tailscale_authkey), sha256(var.web_token),
  ])
}

resource "hcloud_server" "this" {
  name         = var.name
  server_type  = var.server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = [hcloud_ssh_key.this.id]
  firewall_ids = [hcloud_firewall.this.id]
  user_data    = local.user_data

  lifecycle {
    ignore_changes       = [user_data]
    replace_triggered_by = [terraform_data.payload]
  }
}

resource "hcloud_volume_attachment" "workspace" {
  count     = local.use_volume ? 1 : 0
  volume_id = hcloud_volume.workspace[0].id
  server_id = hcloud_server.this.id
}
