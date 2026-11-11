output "task_families" {
  value = { for k, t in aws_ecs_task_definition.psql : k => t.family }
}

output "execution_role_arn" {
  description = "The ONE role a caller must be allowed to iam:PassRole (iam/gkoi-orchestrator-ops.json). There is no task role."
  value       = aws_iam_role.exec.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.psql.name
}

output "run_config_parameter" {
  value = aws_ssm_parameter.run_config.name
}

output "image" {
  value = local.image
}
