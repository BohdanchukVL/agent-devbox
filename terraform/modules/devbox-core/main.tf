terraform {
  required_version = ">= 1.7.0"
}

variable "username" {
  type    = string
  default = "dev"
}

variable "ssh_public_key" {
  type = string
}

variable "runner_ssh_public_key" {
  type    = string
  default = ""
}

variable "install_docker" {
  type    = bool
  default = true
}

variable "install_codex" {
  type    = bool
  default = true
}

variable "install_claude" {
  type    = bool
  default = true
}

variable "install_opencode" {
  type    = bool
  default = false
}

variable "install_antigravity" {
  type    = bool
  default = true
}

variable "install_browser" {
  type    = bool
  default = true
}

variable "tailscale_authkey" {
  type      = string
  default   = ""
  sensitive = true
}

variable "tailscale_enabled" {
  description = "Whether Tailscale is enabled for the devbox"
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "Cloud instance or server type for trigger tracking"
  type        = string
  default     = ""
}

variable "workspace_device" {
  description = "Block device path for the workspace volume, or empty string for root disk"
  type        = string
  default     = ""
}

variable "git_repo" {
  type    = string
  default = ""
}

variable "git_ref" {
  type    = string
  default = "main"
}

variable "git_sha256" {
  type    = string
  default = ""
}

variable "tarball_url" {
  type    = string
  default = ""
}

variable "web_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to connect to SSH. null = auto (open if no tailscale, closed otherwise)."
  type        = list(string)
  default     = null
}

variable "agent_sandbox_strict" {
  description = "Strict sandboxing for agent tools (true = restrict unsandboxed commands)"
  type        = bool
  default     = true
}

variable "release_channel" {
  description = "Release channel for toolchains: 'stable' pins versions, 'latest' uses unpinned latest"
  type        = string
  default     = "stable"
}

variable "secrets_url" {
  description = "Presigned URL for secrets.env payload (WP-3A)"
  type        = string
  default     = ""
  sensitive   = true
}

output "user_data" {
  description = "Rendered cloud-init user_data string"
  value = templatefile("${path.module}/../../../provisioning/cloud-init.yaml", {
    username              = var.username
    ssh_public_key        = var.ssh_public_key
    runner_ssh_public_key = var.runner_ssh_public_key
    install_docker        = var.install_docker
    install_codex         = var.install_codex
    install_claude        = var.install_claude
    install_opencode      = var.install_opencode
    install_antigravity   = var.install_antigravity
    install_browser       = var.install_browser
    tailscale_authkey     = var.tailscale_authkey
    workspace_device      = var.workspace_device
    bootstrap_script      = file("${path.module}/../../../provisioning/bootstrap.sh")
    git_repo              = var.git_repo
    git_ref               = var.git_ref
    git_sha256            = var.git_sha256
    tarball_url           = var.tarball_url
    web_token             = var.web_token
    secrets_url           = var.secrets_url
    agent_sandbox_strict  = var.agent_sandbox_strict
    release_channel       = var.release_channel
  })
  sensitive = true
}

output "ssh_cidrs" {
  description = "Resolved SSH CIDR list"
  value = var.ssh_allowed_cidrs != null ? var.ssh_allowed_cidrs : (
    var.tailscale_enabled ? [] : ["0.0.0.0/0", "::/0"]
  )
}

output "replace_triggers" {
  description = "Trigger string that changes when server must be recreated due to configuration changes"
  value = join(":", [
    var.git_ref,
    var.instance_type,
    var.install_docker,
    var.install_codex,
    var.install_claude,
    var.install_opencode,
    var.install_antigravity,
    var.install_browser,
    var.username,
    tostring(var.agent_sandbox_strict),
    var.release_channel,
    var.workspace_device,
    sha256(var.ssh_public_key)
  ])
}

output "labels" {
  description = "Standard labels/tags for devbox resources across clouds"
  value = {
    managed_by = "agent-devbox"
    user       = var.username
  }
}

