data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Ubuntu 24.04 LTS (Noble) arm64 from Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Network: dedicated VPC, one public subnet, IGW. No NAT gateway (cost).
# The instance has a public IP purely for outbound traffic; the security
# group allows no inbound traffic. Access is via SSM Session Manager or
# Tailscale (both outbound-initiated).
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "hermes" {
  name        = "${var.name}-sg"
  description = "Hermes Agent: no inbound, all outbound"
  vpc_id      = aws_vpc.this.id

  # Intentionally NO ingress rules.

  egress {
    description      = "All outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${var.name}-sg" }
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------
resource "aws_instance" "hermes" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.hermes.id]
  iam_instance_profile   = aws_iam_instance_profile.hermes.name
  # No key_pair: access is via SSM Session Manager / Tailscale SSH only.

  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # allow Docker containers to reach IMDS
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name   = "${var.name}-root"
      Backup = "daily"
    }
  }

  user_data = templatefile("${path.module}/../cloud-init.yaml", {
    region             = var.region
    tailscale_hostname = var.tailscale_hostname
  })

  tags = {
    Name   = var.name
    Backup = "daily"
  }

  lifecycle {
    # Don't replace the instance every time Canonical publishes a new AMI
    # or cloud-init is tweaked; recreate deliberately with -replace.
    ignore_changes = [ami, user_data]
  }
}
