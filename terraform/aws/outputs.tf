output "public_ip" {
  description = "Public IPv4 address of the devbox"
  value       = aws_instance.this.public_ip
}

output "username" {
  description = "SSH user"
  value       = var.username
}

output "ssh_command" {
  description = "Ready-to-paste SSH command"
  value       = "ssh ${var.username}@${aws_instance.this.public_ip}"
}
