# Stage 1 — observability: log groups (30 days), a dashboard skeleton, alarms → the EXISTING gkoi-ops-alerts topics.
# Reads the network, edge-alb and data stacks' state, so it applies after them.

module "regions" {
  source = "../../../modules/regions"
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/network/terraform.tfstate"
    region = "us-west-2"
  }
}

data "terraform_remote_state" "edge" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/edge-alb/terraform.tfstate"
    region = "us-west-2"
  }
}

data "terraform_remote_state" "data" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/data/terraform.tfstate"
    region = "us-west-2"
  }
}

locals {
  r    = module.regions.all
  net  = data.terraform_remote_state.network.outputs
  edge = data.terraform_remote_state.edge.outputs
  data = data.terraform_remote_state.data.outputs

  box_groups = {
    for k, v in local.r : k => concat(
      [for n in var.box_log_streams : "/gkoi/prod2/media/${k}/${n}"],
      [for n in var.box_log_streams : "/gkoi/prod2/game/${k}/${n}"],
    )
  }

  home_alarm_actions = [module.logs_usw2.alerts_topic_arn]
}

# --- log groups -----------------------------------------------------------------------------------------------

module "logs_usw2" {
  source            = "../../../modules/region-log-groups"
  names             = concat([for n in var.ecs_log_streams : "/gkoi/prod2/ecs/${n}"], ["/gkoi/prod2/ops"], local.box_groups.usw2)
  retention_days    = var.log_retention_days
  alerts_topic_name = var.alerts_topic_name
}

module "logs_euc1" {
  source            = "../../../modules/region-log-groups"
  count             = local.r.euc1.enabled ? 1 : 0
  providers         = { aws = aws.euc1 }
  names             = local.box_groups.euc1
  retention_days    = var.log_retention_days
  alerts_topic_name = var.alerts_topic_name
}

module "logs_use1" {
  source            = "../../../modules/region-log-groups"
  count             = local.r.use1.enabled ? 1 : 0
  providers         = { aws = aws.use1 }
  names             = local.box_groups.use1
  retention_days    = var.log_retention_days
  alerts_topic_name = var.alerts_topic_name
}

# Tokyo has no gkoi-ops-alerts topic today: create it before enabling apne1 (README "Enabling a paused region").
module "logs_apne1" {
  source            = "../../../modules/region-log-groups"
  count             = local.r.apne1.enabled ? 1 : 0
  providers         = { aws = aws.apne1 }
  names             = local.box_groups.apne1
  retention_days    = var.log_retention_days
  alerts_topic_name = var.alerts_topic_name
}

# --- alarms (home region) -------------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "gkoi-prod2-rds-cpu-high"
  alarm_description   = "RDS CPU above ${var.rds_cpu_high_pct}% for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = local.data.db_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.rds_cpu_high_pct
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "gkoi-prod2-rds-storage-low"
  alarm_description   = "RDS free storage below ${var.rds_free_storage_low_bytes} bytes"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = local.data.db_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.rds_free_storage_low_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_memory" {
  alarm_name          = "gkoi-prod2-rds-memory-low"
  alarm_description   = "RDS freeable memory below ${var.rds_freeable_memory_low_bytes} bytes for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  dimensions          = { DBInstanceIdentifier = local.data.db_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.rds_freeable_memory_low_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "gkoi-prod2-rds-connections-high"
  alarm_description   = "RDS connections above ${var.rds_connections_high}"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = local.data.db_instance_id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.rds_connections_high
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "valkey_memory" {
  alarm_name          = "gkoi-prod2-valkey-memory-high"
  alarm_description   = "Valkey memory above ${var.valkey_memory_high_pct}% (noeviction: writes fail when full)"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  dimensions          = { ReplicationGroupId = local.data.valkey_id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.valkey_memory_high_pct
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "valkey_cpu" {
  alarm_name          = "gkoi-prod2-valkey-cpu-high"
  alarm_description   = "Valkey engine CPU above 80% for 15 minutes"
  namespace           = "AWS/ElastiCache"
  metric_name         = "EngineCPUUtilization"
  dimensions          = { ReplicationGroupId = local.data.valkey_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "gkoi-prod2-alb-5xx"
  alarm_description   = "The ALB itself answered 5xx more than ${var.alb_5xx_per_5min} times in 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = local.edge.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.alb_5xx_per_5min
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

# Unhealthy targets: no targets yet = 0 / missing = OK, so these stay quiet until P3/P4 registers tasks.
resource "aws_cloudwatch_metric_alarm" "tg_unhealthy" {
  for_each            = local.edge.target_groups
  alarm_name          = "gkoi-prod2-${each.key}-unhealthy"
  alarm_description   = "${each.key}: an unhealthy target for 5 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = local.edge.alb_arn_suffix, TargetGroup = each.value.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "efs_io_limit" {
  alarm_name          = "gkoi-prod2-efs-io-limit"
  alarm_description   = "EFS PercentIOLimit above 90% for 15 minutes"
  namespace           = "AWS/EFS"
  metric_name         = "PercentIOLimit"
  dimensions          = { FileSystemId = local.data.efs_id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.home_alarm_actions
  ok_actions          = local.home_alarm_actions
}

# --- dashboard skeleton ---------------------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "prod2" {
  dashboard_name = "gkoi-prod2"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "## GKOI prod2 — control plane (us-west-2)\nSkeleton: services, media and game widgets are added with their stacks." }
      },
      {
        type = "metric", x = 0, y = 2, width = 12, height = 6
        properties = {
          title  = "ALB requests / 5xx"
          region = "us-west-2"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.edge.alb_arn_suffix],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 12, height = 6
        properties = {
          title   = "ALB target response time (p95)"
          region  = "us-west-2"
          stat    = "p95"
          period  = 300
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.edge.alb_arn_suffix]]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title  = "RDS CPU / connections"
          region = "us-west-2"
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.data.db_instance_id],
            [".", "DatabaseConnections", ".", ".", { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title  = "Valkey memory % / engine CPU"
          region = "us-west-2"
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "ReplicationGroupId", local.data.valkey_id],
            [".", "EngineCPUUtilization", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 12, height = 6
        properties = {
          title  = "EFS IO limit / throughput"
          region = "us-west-2"
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/EFS", "PercentIOLimit", "FileSystemId", local.data.efs_id],
            [".", "MeteredIOBytes", ".", ".", { stat = "Sum", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}
