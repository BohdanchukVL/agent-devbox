locals {
  is_arm   = can(regex("^(t4g|c7g|m7g|r7g|c6g|m6g|r6g|a1)\\.", var.instance_type))
  ami_arch = local.is_arm ? "arm64" : "amd64"

  ssh_cidrs = var.ssh_allowed_cidrs != null ? var.ssh_allowed_cidrs : (
    var.tailscale_authkey != "" ? [] : ["0.0.0.0/0", "::/0"]
  )

  ssh_ipv4_cidrs = [for c in local.ssh_cidrs : c if !can(regex(":", c))]
  ssh_ipv6_cidrs = [for c in local.ssh_cidrs : c if can(regex(":", c))]

  user_data = templatefile("${path.module}/../../provisioning/cloud-init.yaml", {
    username            = var.username
    ssh_public_key      = var.ssh_public_key
    install_docker      = var.install_docker
    install_codex       = var.install_codex
    install_claude      = var.install_claude
    install_opencode    = var.install_opencode
    install_antigravity = var.install_antigravity
    install_browser     = var.install_browser
    tailscale_authkey   = var.tailscale_authkey
    workspace_device    = ""
    bootstrap_script    = file("${path.module}/../../provisioning/bootstrap.sh")
    git_repo            = var.git_repo
    git_ref             = var.git_ref
    git_token           = var.git_token
    git_sha256          = var.git_sha256
    tarball_url         = var.tarball_url
    web_token           = var.web_token
  })
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Self-contained network — no dependency on a default VPC existing.
resource "aws_vpc" "this" {
  cidr_block           = "10.80.0.0/16"
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.80.1.0/24"
  map_public_ip_on_launch = true

  tags = { Name = var.name }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = var.name }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

resource "aws_security_group" "this" {
  name        = "${var.name}-ssh"
  description = "agent-devbox: SSH and WireGuard"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = length(local.ssh_ipv4_cidrs) > 0 || length(local.ssh_ipv6_cidrs) > 0 ? [1] : []
    content {
      description      = "SSH"
      from_port        = 22
      to_port          = 22
      protocol         = "tcp"
      cidr_blocks      = local.ssh_ipv4_cidrs
      ipv6_cidr_blocks = local.ssh_ipv6_cidrs
    }
  }

  dynamic "ingress" {
    for_each = var.tailscale_authkey != "" ? [1] : []
    content {
      description      = "Tailscale WireGuard"
      from_port        = 41641
      to_port          = 41641
      protocol         = "udp"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = var.name }
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name}-key"
  public_key = var.ssh_public_key
}

resource "terraform_data" "payload" {
  input = "${var.git_ref}:${var.install_docker}:${var.install_codex}:${var.install_claude}:${var.install_opencode}:${var.install_antigravity}:${var.install_browser}:${var.username}"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.this.id
  vpc_security_group_ids = [aws_security_group.this.id]
  key_name               = aws_key_pair.this.key_name
  user_data              = local.user_data

  lifecycle {
    ignore_changes       = [user_data]
    replace_triggered_by = [terraform_data.payload]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.disk_size
    volume_type = "gp3"
  }

  tags = { Name = var.name }
}
