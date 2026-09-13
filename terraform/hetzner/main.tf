module "core" {
  source = "../modules/devbox-core"

  username              = var.username
  instance_type         = var.server_type
  ssh_public_key        = var.ssh_public_key
  runner_ssh_public_key = var.runner_ssh_public_key
  install_docker        = var.install_docker
  install_codex         = var.install_codex
  install_claude        = var.install_claude
  install_opencode      = var.install_opencode
  install_antigravity   = var.install_antigravity
  install_browser       = var.install_browser
  tailscale_authkey     = var.tailscale_authkey
  workspace_device      = local.use_volume ? "/dev/disk/by-id/scsi-0HC_Volume_${hcloud_volume.workspace[0].id}" : ""
  git_repo              = var.git_repo
  git_ref               = var.git_ref
  git_sha256            = var.git_sha256
  tarball_url           = var.tarball_url
  web_token             = var.web_token
  ssh_allowed_cidrs     = var.ssh_allowed_cidrs
  secrets_url           = var.secrets_url
  agent_sandbox_strict  = var.agent_sandbox_strict
  release_channel       = var.release_channel
}

data "hcloud_ssh_keys" "all" {}

locals {
  use_volume = var.disk_size > 0
  ssh_cidrs  = module.core.ssh_cidrs
  user_data  = module.core.user_data

  # Compare base64 key payloads to find if key is already registered in Hetzner project
  user_key_parts = split(" ", trimspace(var.ssh_public_key))
  user_key_token = length(local.user_key_parts) >= 2 ? local.user_key_parts[1] : trimspace(var.ssh_public_key)

  matching_keys = [
    for k in data.hcloud_ssh_keys.all.ssh_keys : k.id
    if(
      trimspace(k.public_key) == trimspace(var.ssh_public_key) ||
      (length(split(" ", trimspace(k.public_key))) >= 2 && split(" ", trimspace(k.public_key))[1] == local.user_key_token)
    )
  ]

  key_already_exists = length(local.matching_keys) > 0
  ssh_key_id         = local.key_already_exists ? local.matching_keys[0] : (length(hcloud_ssh_key.this) > 0 ? hcloud_ssh_key.this[0].id : null)
}

resource "hcloud_ssh_key" "this" {
  count      = local.key_already_exists ? 0 : 1
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
  input = module.core.replace_triggers
}

resource "hcloud_server" "this" {
  name         = var.name
  server_type  = var.server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = [local.ssh_key_id]
  firewall_ids = [hcloud_firewall.this.id]
  labels       = module.core.labels
  user_data    = local.user_data
  backups      = var.backups

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
