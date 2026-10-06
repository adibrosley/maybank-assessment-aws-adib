# Platform-owned spoke VPC module. App teams consume the outputs (subnet IDs)
# but cannot change routing: the default route always points to the Transit
# Gateway, so all egress and hybrid traffic passes the central Network Firewall.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_availability_zones" "this" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.this.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name })
}

# Two tiers per AZ: app (EKS, internal ALB) and data (Aurora).
# No public subnets, no Internet Gateway, no NAT: by design.
resource "aws_subnet" "app" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index)
  availability_zone = local.azs[count.index]
  tags = merge(var.tags, {
    Name                              = "${var.name}-app-${local.azs[count.index]}"
    tier                              = "app"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.name
  })
}

resource "aws_subnet" "data" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 8)
  availability_zone = local.azs[count.index]
  tags              = merge(var.tags, { Name = "${var.name}-data-${local.azs[count.index]}", tier = "data" })
}

# TGW attachment uses the app subnets (one ENI per AZ).
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count              = var.transit_gateway_id == null ? 0 : 1
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.app[*].id
  tags               = merge(var.tags, { Name = "${var.name}-tgw" })
}

# Routes are declared INLINE (not as separate aws_route resources) on purpose.
# Inline routes make Terraform the exclusive owner of the table: any route added
# outside Terraform (e.g. 0.0.0.0/0 -> igw-xxx) shows up in `terraform plan` as drift
# and is removed on apply. With separate aws_route resources, an extra unmanaged
# route would be invisible to Terraform. (VPC endpoint routes are ignored by the
# provider, so the S3 gateway endpoint below does not cause perpetual diffs.)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.transit_gateway_id == null ? [] : [var.transit_gateway_id]
    content {
      cidr_block         = "0.0.0.0/0"
      transit_gateway_id = route.value
    }
  }

  tags       = merge(var.tags, { Name = "${var.name}-private", managed_by = "terraform-platform" })
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "app" {
  count          = var.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "data" {
  count          = var.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private.id
}

# S3 gateway endpoint: free, keeps S3 traffic off TGW/NAT (cost and security).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = var.tags
}

# Flow logs to the central Log Archive bucket (evidence for Task 4).
resource "aws_flow_log" "this" {
  count                = var.flow_log_bucket_arn == null ? 0 : 1
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = var.flow_log_bucket_arn
  tags                 = var.tags
}
