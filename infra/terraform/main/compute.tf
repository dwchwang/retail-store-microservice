data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "admin" {
  key_name   = "retail-store"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

locals {
  common_instance = {
    ami                    = data.aws_ami.ubuntu.id
    subnet_id              = aws_subnet.public.id
    vpc_security_group_ids = [aws_security_group.cluster.id]
    key_name               = aws_key_pair.admin.key_name
  }
}

resource "aws_instance" "server" {
  ami                    = local.common_instance.ami
  instance_type          = var.server_instance_type
  subnet_id              = local.common_instance.subnet_id
  vpc_security_group_ids = local.common_instance.vpc_security_group_ids
  key_name               = local.common_instance.key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  tags = { Name = "server-1", Role = "rke2-server" }

  # AMI mới ra không làm tạo lại máy
  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_instance" "agent" {
  count                  = var.agent_count
  ami                    = local.common_instance.ami
  instance_type          = var.agent_instance_type
  subnet_id              = local.common_instance.subnet_id
  vpc_security_group_ids = local.common_instance.vpc_security_group_ids
  key_name               = local.common_instance.key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "agent-${count.index + 1}", Role = "rke2-agent" }

  lifecycle {
    ignore_changes = [ami]
  }
}

# IP cố định cho server: kubeconfig và tls-san không đổi khi stop/start
resource "aws_eip" "server" {
  instance = aws_instance.server.id
  domain   = "vpc"
  tags     = { Name = "server-1-eip" }
}