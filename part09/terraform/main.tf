terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "zones" {
  description = "Subnet ranges per availability zone, from the plan in Part 2"
  type = map(object({
    public = string
    app    = string
    data   = string
  }))
  default = {
    "us-east-1a" = { public = "10.20.108.0/24", app = "10.20.0.0/19", data = "10.20.96.0/22" }
    "us-east-1b" = { public = "10.20.109.0/24", app = "10.20.32.0/19", data = "10.20.100.0/22" }
  }
}

locals {
  # { "public-a" = { zone = "us-east-1a", tier = "public", cidr = "10.20.108.0/24" }, ... }
  subnets = merge([
    for zone, ranges in var.zones : {
      for tier, cidr in ranges : "${tier}-${substr(zone, -1, 1)}" => { zone = zone, tier = tier, cidr = cidr }
    }
  ]...)
}

resource "aws_vpc" "shop" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "shop" }
}

resource "aws_subnet" "this" {
  for_each          = local.subnets
  vpc_id            = aws_vpc.shop.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.zone
  tags              = { Name = each.key, Tier = each.value.tier }
}

resource "aws_internet_gateway" "shop" {
  vpc_id = aws_vpc.shop.id
}

resource "aws_nat_gateway" "shop" {
  vpc_id            = aws_vpc.shop.id
  availability_mode = "regional"
  depends_on        = [aws_internet_gateway.shop]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.shop.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.shop.id
  }
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.shop.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.shop.id
  }
}

# no default route: the data tier never talks to the internet
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.shop.id
}

locals {
  route_tables = {
    public = aws_route_table.public.id
    app    = aws_route_table.app.id
    data   = aws_route_table.data.id
  }
}

resource "aws_route_table_association" "this" {
  for_each       = local.subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = local.route_tables[each.value.tier]
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.shop.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id, aws_route_table.data.id]
}

resource "aws_security_group" "tier" {
  for_each    = toset(["lb", "app", "db"])
  name        = "shop-${each.key}"
  description = "shop ${each.key} tier"
  vpc_id      = aws_vpc.shop.id
}

resource "aws_vpc_security_group_ingress_rule" "lb_https" {
  security_group_id = aws_security_group.tier["lb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "app_from_lb" {
  security_group_id            = aws_security_group.tier["app"].id
  referenced_security_group_id = aws_security_group.tier["lb"].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.tier["db"].id
  referenced_security_group_id = aws_security_group.tier["app"].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# Terraform removes the default "allow all outbound" rule, so outbound is explicit too
resource "aws_vpc_security_group_egress_rule" "lb_to_app" {
  security_group_id            = aws_security_group.tier["lb"].id
  referenced_security_group_id = aws_security_group.tier["app"].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "app_out" {
  security_group_id = aws_security_group.tier["app"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

output "subnet_ids" {
  value = { for name, subnet in aws_subnet.this : name => subnet.id }
}
