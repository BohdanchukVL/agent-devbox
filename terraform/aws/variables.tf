variable "name" {
  description = "Base name for all resources"
  type        = string
  default     = "agent-devbox"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "disk_size" {
  description = "Root volume size in GB (workspace lives on the root disk)"
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
