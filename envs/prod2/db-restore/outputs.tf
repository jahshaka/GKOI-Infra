output "transit_bucket" {
  value = aws_s3_bucket.transit.id
}

output "task_families" {
  value = { for k, t in aws_ecs_task_definition.restore : k => t.family }
}

output "log_group" {
  value = aws_cloudwatch_log_group.restore.name
}

output "run_config_parameter" {
  value = aws_ssm_parameter.run_config.name
}

output "images" {
  value = local.image
}
