output "vpc_id" {
  value = aws_vpc.this.id
}

output "cidr" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

output "all_route_table_ids" {
  value = concat([aws_route_table.public.id], aws_route_table.private[*].id)
}

output "nat_public_ips" {
  value = aws_eip.nat[*].public_ip
}

output "endpoints_security_group_id" {
  value = length(aws_security_group.endpoints) > 0 ? aws_security_group.endpoints[0].id : null
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
