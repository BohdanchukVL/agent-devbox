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
