output "public_ip" {
  description = "Public IPv4 address of the devbox"
  value       = azurerm_public_ip.this.ip_address
}

output "username" {
  description = "SSH user"
  value       = var.username
}

output "ssh_command" {
  description = "Ready-to-paste SSH command"
  value       = "ssh ${var.username}@${azurerm_public_ip.this.ip_address}"
}
