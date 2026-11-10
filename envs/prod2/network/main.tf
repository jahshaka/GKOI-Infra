# Stage 1 — network: one VPC per enabled region, hub-and-spoke peering from us-west-2, flow logs, and the shared
# security group the home region's ECS tasks will use (the data stack lets only this SG reach RDS / Valkey / EFS).

module "regions" {
  source = "../../../modules/regions"
}

locals {
  r    = module.regions.all
  home = module.regions.home_key
}

# --- flow-log role (IAM is global; one role serves every region) --------------------------------------------------

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "gkoi-prod2-vpc-flow-logs"
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
}

data "aws_iam_policy_document" "flow_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:*:${var.account_id}:log-group:/gkoi/prod2/vpc-flow/*",
      "arn:aws:logs:*:${var.account_id}:log-group:/gkoi/prod2/vpc-flow/*:*",
    ]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_write.json
}

# --- VPCs ------------------------------------------------------------------------------------------------------

module "vpc_usw2" {
  source                  = "../../../modules/vpc"
  name                    = "gkoi-prod2-usw2"
  cidr                    = local.r.usw2.cidr
  azs                     = local.r.usw2.azs
  nat_mode                = var.home_nat_mode
  interface_endpoints     = var.home_interface_endpoints
  flow_log_group_name     = "/gkoi/prod2/vpc-flow/usw2"
  flow_log_retention_days = var.flow_log_retention_days
  flow_log_traffic_type   = var.flow_log_traffic_type
  flow_log_role_arn       = aws_iam_role.flow_logs.arn
}

module "vpc_euc1" {
  source                  = "../../../modules/vpc"
  count                   = local.r.euc1.enabled ? 1 : 0
  providers               = { aws = aws.euc1 }
  name                    = "gkoi-prod2-euc1"
  cidr                    = local.r.euc1.cidr
  azs                     = local.r.euc1.azs
  nat_mode                = var.edge_nat_mode
  map_public_ip_on_launch = true
  flow_log_group_name     = "/gkoi/prod2/vpc-flow/euc1"
  flow_log_retention_days = var.flow_log_retention_days
  flow_log_traffic_type   = var.flow_log_traffic_type
  flow_log_role_arn       = aws_iam_role.flow_logs.arn
}

module "vpc_use1" {
  source                  = "../../../modules/vpc"
  count                   = local.r.use1.enabled ? 1 : 0
  providers               = { aws = aws.use1 }
  name                    = "gkoi-prod2-use1"
  cidr                    = local.r.use1.cidr
  azs                     = local.r.use1.azs
  nat_mode                = var.edge_nat_mode
  map_public_ip_on_launch = true
  flow_log_group_name     = "/gkoi/prod2/vpc-flow/use1"
  flow_log_retention_days = var.flow_log_retention_days
  flow_log_traffic_type   = var.flow_log_traffic_type
  flow_log_role_arn       = aws_iam_role.flow_logs.arn
}

module "vpc_apne1" {
  source                  = "../../../modules/vpc"
  count                   = local.r.apne1.enabled ? 1 : 0
  providers               = { aws = aws.apne1 }
  name                    = "gkoi-prod2-apne1"
  cidr                    = local.r.apne1.cidr
  azs                     = local.r.apne1.azs
  nat_mode                = var.edge_nat_mode
  map_public_ip_on_launch = true
  flow_log_group_name     = "/gkoi/prod2/vpc-flow/apne1"
  flow_log_retention_days = var.flow_log_retention_days
  flow_log_traffic_type   = var.flow_log_traffic_type
  flow_log_role_arn       = aws_iam_role.flow_logs.arn
}

# --- peering: hub usw2 ↔ each spoke --------------------------------------------------------------------------

module "peer_euc1" {
  source                    = "../../../modules/vpc-peering"
  count                     = local.r.euc1.enabled ? 1 : 0
  providers                 = { aws.requester = aws, aws.accepter = aws.euc1 }
  name                      = "gkoi-prod2-usw2-euc1"
  requester_vpc_id          = module.vpc_usw2.vpc_id
  requester_cidr            = module.vpc_usw2.cidr
  requester_route_table_ids = module.vpc_usw2.all_route_table_ids
  accepter_vpc_id           = module.vpc_euc1[0].vpc_id
  accepter_region           = local.r.euc1.region
  accepter_cidr             = module.vpc_euc1[0].cidr
  accepter_route_table_ids  = module.vpc_euc1[0].all_route_table_ids
}

module "peer_use1" {
  source                    = "../../../modules/vpc-peering"
  count                     = local.r.use1.enabled ? 1 : 0
  providers                 = { aws.requester = aws, aws.accepter = aws.use1 }
  name                      = "gkoi-prod2-usw2-use1"
  requester_vpc_id          = module.vpc_usw2.vpc_id
  requester_cidr            = module.vpc_usw2.cidr
  requester_route_table_ids = module.vpc_usw2.all_route_table_ids
  accepter_vpc_id           = module.vpc_use1[0].vpc_id
  accepter_region           = local.r.use1.region
  accepter_cidr             = module.vpc_use1[0].cidr
  accepter_route_table_ids  = module.vpc_use1[0].all_route_table_ids
}

module "peer_apne1" {
  source                    = "../../../modules/vpc-peering"
  count                     = local.r.apne1.enabled ? 1 : 0
  providers                 = { aws.requester = aws, aws.accepter = aws.apne1 }
  name                      = "gkoi-prod2-usw2-apne1"
  requester_vpc_id          = module.vpc_usw2.vpc_id
  requester_cidr            = module.vpc_usw2.cidr
  requester_route_table_ids = module.vpc_usw2.all_route_table_ids
  accepter_vpc_id           = module.vpc_apne1[0].vpc_id
  accepter_region           = local.r.apne1.region
  accepter_cidr             = module.vpc_apne1[0].cidr
  accepter_route_table_ids  = module.vpc_apne1[0].all_route_table_ids
}

# --- the home region's ECS task SG (rules added by edge-alb / data; egress open) -----------------------------

resource "aws_security_group" "ecs_tasks" {
  name        = "gkoi-prod2-ecs-tasks"
  description = "The control-plane ECS tasks. Ingress rules are owned by edge-alb; data stores allow this SG."
  vpc_id      = module.vpc_usw2.vpc_id
  tags        = { Name = "gkoi-prod2-ecs-tasks" }
}

resource "aws_vpc_security_group_egress_rule" "ecs_tasks_all" {
  security_group_id = aws_security_group.ecs_tasks.id
  description       = "All egress (NAT, endpoints, data stores, peered regions)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
