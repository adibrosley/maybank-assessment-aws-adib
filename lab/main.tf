# ---------------------------------------------------------------------------
# PERSONAL LAB: cheap, safe slice of the design you can deploy through Jenkins.
# Creates: VPC, 2 private subnets in 2 AZs, a route table Terraform fully owns.
# Cost: VPC/subnets/route tables are free. No NAT, no TGW, no EC2.
# Use your OWN sandbox AWS account, never a company account.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {} # values come from backend.hcl (see lab/README.md)
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      app         = "payments-lab"
      env         = var.env
      cost-centre = "personal-lab"
      managed-by  = "terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "env" {
  type    = string
  default = "lab"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "payments-lab-vpc" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  cidr_block        = cidrsubnet(aws_vpc.lab.cidr_block, 8, count.index) # 10.99.0.0/24, 10.99.1.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "payments-lab-private-${count.index}" }
}

# route = [] means: "Terraform owns every route in this table, and there should
# be none except the implicit 'local' route". If someone adds 0.0.0.0/0 -> IGW in
# the console, the next plan shows it as drift. This is the Task 4 scenario.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  route  = []
  tags   = { Name = "payments-lab-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Lock down the default security group (Checkov/CIS: no rules on default SG).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.lab.id
}

output "vpc_id" { value = aws_vpc.lab.id }
output "route_table_id" { value = aws_route_table.private.id }
output "subnet_ids" { value = aws_subnet.private[*].id }
