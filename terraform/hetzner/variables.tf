variable "name" {
  description = "Base name for all resources"
  type        = string
  default     = "agent-devbox"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx33"
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "nbg1"
}

variable "disk_size" {
  description = "Size in GB of the extra volume mounted at /workspace (0 = keep workspace on the root disk)"
  type        = number
  default     = 80
}

variable "username" {
  description = "Unprivileged user created on the machine"
  type        = string
  default     = "dev"
}

variable "ssh_public_key" {
  description = "SSH public key granted access to the machine"
  type        = string
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
  description = "Google Antigravity CLI (agy)"
  type        = bool
  default     = true
}

variable "install_browser" {
  description = "Headless Chromium (Playwright) for agent web-testing"
  type        = bool
  default     = true
}

variable "tailscale_authkey" {
  description = "Tailscale auth key for joining the tailnet automatically (optional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to connect to SSH (port 22). If null and tailscale_authkey is set, port 22 is closed from internet."
  type        = list(string)
  default     = null
}

variable "git_repo" {
  description = "GitHub repository (owner/repo) to pull provisioning scripts from if tarball_url is not set"
  type        = string
  default     = ""
}

variable "git_ref" {
  description = "Git ref (branch, tag, or commit SHA) to pull provisioning scripts from"
  type        = string
  default     = "main"
}

variable "git_token" {
  description = "GitHub personal access token for private repository provisioning payload"
  type        = string
  default     = ""
  sensitive   = true
}

variable "git_sha256" {
  description = "Optional SHA256 checksum to verify provisioning payload archive"
  type        = string
  default     = ""
}

variable "tarball_url" {
  description = "Optional custom URL pointing directly to a provisioning tarball archive"
  type        = string
  default     = ""
}

variable "web_token" {
  description = "Authentication token for devbox-web companion gateway"
  type        = string
  default     = ""
  sensitive   = true
}

