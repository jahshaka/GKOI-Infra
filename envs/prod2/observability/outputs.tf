output "alerts_topic_arns" {
  description = "The existing gkoi-ops-alerts topic per enabled region (for the media/game stacks' alarms)."
  value = merge(
    { usw2 = module.logs_usw2.alerts_topic_arn },
    length(module.logs_euc1) > 0 ? { euc1 = module.logs_euc1[0].alerts_topic_arn } : {},
    length(module.logs_use1) > 0 ? { use1 = module.logs_use1[0].alerts_topic_arn } : {},
    length(module.logs_apne1) > 0 ? { apne1 = module.logs_apne1[0].alerts_topic_arn } : {},
  )
}

output "log_groups" {
  value = concat(
    module.logs_usw2.log_groups,
    flatten(module.logs_euc1[*].log_groups),
    flatten(module.logs_use1[*].log_groups),
    flatten(module.logs_apne1[*].log_groups),
  )
}

output "dashboard" {
  value = aws_cloudwatch_dashboard.prod2.dashboard_name
}
