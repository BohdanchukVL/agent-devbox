locals {
  user_data = templatefile("${path.module}/../../provisioning/cloud-init.yaml", {
    username            = var.username
    ssh_public_key      = var.ssh_public_key
    install_docker      = var.install_docker
    install_codex       = var.install_codex
    install_claude      = var.install_claude
    install_opencode    = var.install_opencode
    install_antigravity = var.install_antigravity
    install_browser     = var.install_browser
    workspace_device    = ""
    install_base        = file("${path.module}/../../provisioning/install-base.sh")
    install_agents      = file("${path.module}/../../provisioning/install-agents.sh")
    browser             = file("${path.module}/../../provisioning/install-browser.sh")
    install_shell       = file("${path.module}/../../provisioning/install-shell.sh")

    zshrc       = file("${path.module}/../../provisioning/zshrc")
    motd        = file("${path.module}/../../provisioning/motd.sh")
    tmux_conf   = file("${path.module}/../../provisioning/tmux.conf")
    tmux_status = file("${path.module}/../../provisioning/tmux-status.sh")
    osc7        = file("${path.module}/../../provisioning/osc7.sh")
  })
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
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
  description = "agent-devbox: SSH only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description      = "SSH"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
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

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.this.id
  vpc_security_group_ids = [aws_security_group.this.id]
  key_name               = aws_key_pair.this.key_name
  user_data              = local.user_data

  root_block_device {
    volume_size = var.disk_size
    volume_type = "gp3"
  }

  tags = { Name = var.name }
}
