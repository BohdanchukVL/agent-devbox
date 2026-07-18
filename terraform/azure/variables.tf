variable "name" {
  description = "Base name for all resources"
  type        = string
  default     = "agent-devbox"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_B2ms"
}

variable "disk_size" {
  description = "OS disk size in GB (workspace lives on the OS disk)"
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
  default     = false
}

variable "install_browser" {
  description = "Headless Chromium (Playwright) for agent web-testing"
  type        = bool
  default     = true
}
