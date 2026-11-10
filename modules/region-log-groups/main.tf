# CloudWatch log groups in one region (the provider's), plus a read of that region's EXISTING ops-alerts topic.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
  }
}

variable "names" {
  type = list(string)
}

variable "retention_days" {
  type    = number
  default = 30
}

variable "alerts_topic_name" {
  description = "The EXISTING SNS topic in this region (read only, never created here)."
  type        = string
}

resource "aws_cloudwatch_log_group" "this" {
  for_each          = toset(var.names)
  name              = each.value
  retention_in_days = var.retention_days
}

data "aws_sns_topic" "alerts" {
  name = var.alerts_topic_name
}

output "log_groups" {
  value = [for g in aws_cloudwatch_log_group.this : g.name]
}

output "alerts_topic_arn" {
  value = data.aws_sns_topic.alerts.arn
}
