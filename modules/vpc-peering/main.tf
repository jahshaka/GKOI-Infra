# Inter-region VPC peering, hub (requester, us-west-2) ↔ spoke (accepter), with routes on both sides and remote DNS
# resolution. Peering is not transitive: spokes reach the hub only, never each other.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.80, < 6.0"
      configuration_aliases = [aws.requester, aws.accepter]
    }
  }
}

variable "name" {
  type = string
}

variable "requester_vpc_id" {
  type = string
}

variable "requester_cidr" {
  type = string
}

variable "requester_route_table_ids" {
  type = list(string)
}

variable "accepter_vpc_id" {
  type = string
}

variable "accepter_region" {
  type = string
}

variable "accepter_cidr" {
  type = string
}

variable "accepter_route_table_ids" {
  type = list(string)
}

resource "aws_vpc_peering_connection" "this" {
  provider    = aws.requester
  vpc_id      = var.requester_vpc_id
  peer_vpc_id = var.accepter_vpc_id
  peer_region = var.accepter_region
  auto_accept = false
  tags        = { Name = var.name, side = "requester" }
}

resource "aws_vpc_peering_connection_accepter" "this" {
  provider                  = aws.accepter
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true
  tags                      = { Name = var.name, side = "accepter" }
}

resource "aws_vpc_peering_connection_options" "requester" {
  provider                  = aws.requester
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider                  = aws.accepter
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "requester" {
  provider                  = aws.requester
  count                     = length(var.requester_route_table_ids)
  route_table_id            = var.requester_route_table_ids[count.index]
  destination_cidr_block    = var.accepter_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}

resource "aws_route" "accepter" {
  provider                  = aws.accepter
  count                     = length(var.accepter_route_table_ids)
  route_table_id            = var.accepter_route_table_ids[count.index]
  destination_cidr_block    = var.requester_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id
}

output "id" {
  value = aws_vpc_peering_connection_accepter.this.id
}
