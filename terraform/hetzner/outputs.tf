output "public_ip" {
  description = "Public IPv4 address of the devbox"
  value       = hcloud_server.this.ipv4_address
}

output "username" {
  description = "SSH user"
  value       = var.username
}

output "ssh_command" {
  description = "Ready-to-paste SSH command"
  value       = "ssh ${var.username}@${hcloud_server.this.ipv4_address}"
}
