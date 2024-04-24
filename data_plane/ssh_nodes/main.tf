##################################################################################
# CONFIGURATION 
##################################################################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "15.2.0"
    }
  }
}
##################################################################################
# PROVIDERS
##################################################################################
provider "aws" {
  region = var.aws_region
}

provider "teleport" {
  addr               = "${var.proxy_service_address}:443"
  identity_file_path = "/tmp/terraform-output/identity"
}
##################################################################################
# RESOURCES
##################################################################################
resource "random_string" "token" {
  count  = var.agent_count
  length = 32
}

resource "teleport_provision_token" "agent" {
  version = "v2"
  count = var.agent_count
  spec = {
    roles = [
      "Node",
      "App",
      "Db",
      "Kube",
    ]
    name = random_string.token[count.index].result
  }
  metadata = {
    expires = timeadd(timestamp(), "1h")
  }
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
}

resource "aws_security_group" "egress" {
  depends_on = [ aws_vpc.main ]
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "dlg-egress"
  }
  name = "allow outbound"
  description = "allow egress access to internet for ec2 instances"
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_internet_gateway" "main" {
  depends_on = [ aws_vpc.main ]
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "dlg-ig"
  }
}

resource "aws_subnet" "main" {
  depends_on = [ aws_vpc.main ]
  cidr_block = "10.0.0.0/24"
  map_public_ip_on_launch = true
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "dlg-subnet"
  }
}

resource "aws_route_table" "main" {
  depends_on = [ aws_vpc.main, aws_internet_gateway.main ]
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "dlg-route-table"
  }
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "main" {
  depends_on = [ aws_subnet.main, aws_route_table.main ]
  subnet_id = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

resource "aws_instance" "teleport_agent" {
  count = var.agent_count
  # Amazon Linux 2023 64-bit x86
  ami           = "ami-01103fb68b3569475"
  instance_type = "t3.micro"
  subnet_id = aws_subnet.main.id
  vpc_security_group_ids = [ aws_security_group.egress.id ]
  user_data = templatefile("./config/userdata", {
    token                 = teleport_provision_token.agent[count.index].metadata.name
    proxy_service_address = var.proxy_service_address
    teleport_version      = var.teleport_version
  })

  // The following two blocks adhere to security best practices.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted = true
  }
  tags = {
    Name = "dlg-ssh-${count.index}"
  }
}
##################################################################################