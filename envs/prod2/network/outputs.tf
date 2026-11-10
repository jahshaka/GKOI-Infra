locals {
  vpc_modules = merge(
    { usw2 = module.vpc_usw2 },
    length(module.vpc_euc1) > 0 ? { euc1 = module.vpc_euc1[0] } : {},
    length(module.vpc_use1) > 0 ? { use1 = module.vpc_use1[0] } : {},
    length(module.vpc_apne1) > 0 ? { apne1 = module.vpc_apne1[0] } : {},
  )
}

output "home_key" {
  value = local.home
}

output "regions" {
  description = "Per enabled region: the AWS region, VPC, subnets and route tables."
  value = {
    for k, m in local.vpc_modules : k => {
      region                  = local.r[k].region
      role                    = local.r[k].role
      vpc_id                  = m.vpc_id
      cidr                    = m.cidr
      azs                     = m.azs
      public_subnet_ids       = m.public_subnet_ids
      private_subnet_ids      = m.private_subnet_ids
      public_route_table_id   = m.public_route_table_id
      private_route_table_ids = m.private_route_table_ids
      nat_public_ips          = m.nat_public_ips
      s3_endpoint_id          = m.s3_endpoint_id
    }
  }
}

output "home_vpc_id" {
  value = module.vpc_usw2.vpc_id
}

output "home_cidr" {
  value = module.vpc_usw2.cidr
}

output "home_public_subnet_ids" {
  value = module.vpc_usw2.public_subnet_ids
}

output "home_private_subnet_ids" {
  value = module.vpc_usw2.private_subnet_ids
}

output "home_nat_public_ips" {
  description = "The control plane's egress addresses (for third-party allow-lists)."
  value       = module.vpc_usw2.nat_public_ips
}

output "home_endpoints_security_group_id" {
  value = module.vpc_usw2.endpoints_security_group_id
}

output "edge_cidrs" {
  description = "The peered media/game VPC CIDRs (for data-store rules that must admit media boxes later)."
  value       = { for k, m in local.vpc_modules : k => m.cidr if k != local.home }
}

output "ecs_tasks_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}

output "peering_ids" {
  value = merge(
    length(module.peer_euc1) > 0 ? { euc1 = module.peer_euc1[0].id } : {},
    length(module.peer_use1) > 0 ? { use1 = module.peer_use1[0].id } : {},
    length(module.peer_apne1) > 0 ? { apne1 = module.peer_apne1[0].id } : {},
  )
}
