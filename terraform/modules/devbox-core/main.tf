# devbox-core — shared user_data generation for all providers.
# Each provider module calls this to get the cloud-init user_data string.

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

variable "git_token" {
  type      = string
  default   = ""
  sensitive = true
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

output "user_data" {
  description = "Rendered cloud-init user_data string"
  value = templatefile("${path.module}/../../provisioning/cloud-init.yaml", {
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
    bootstrap_script      = file("${path.module}/../../provisioning/bootstrap.sh")
    git_repo              = var.git_repo
    git_ref               = var.git_ref
    git_token             = var.git_token
    git_sha256            = var.git_sha256
    tarball_url           = var.tarball_url
    web_token             = var.web_token
  })
  sensitive = true
}

output "ssh_cidrs" {
  description = "Resolved SSH CIDR list"
  value = var.ssh_allowed_cidrs != null ? var.ssh_allowed_cidrs : (
    var.tailscale_authkey != "" ? [] : ["0.0.0.0/0", "::/0"]
  )
}
