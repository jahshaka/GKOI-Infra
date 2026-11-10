output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "services" {
  description = "service name → task-definition family (the ECS service names inside cluster gkoi-prod2)."
  value = merge(
    {
      (module.cms.service_name)           = module.cms.task_definition_family
      (module.engine_api.service_name)    = module.engine_api.task_definition_family
      (module.engine_worker.service_name) = module.engine_worker.task_definition_family
      (module.fm_api.service_name)        = module.fm_api.task_definition_family
      (module.fm_worker.service_name)     = module.fm_worker.task_definition_family
    },
    { for m in module.fm_web : m.service_name => m.task_definition_family },
  )
}

output "migrate_task_families" {
  description = "Run ONE before the matching service update: ecs run-task --cluster gkoi-prod2 --launch-type FARGATE --task-definition <family> --network-configuration (run_task_network)."
  value       = { for k, t in aws_ecs_task_definition.migrate : k => t.family }
}

output "run_task_network" {
  description = "The awsvpcConfiguration a one-off run-task needs (the services' own subnets + SG, no public IP)."
  value = {
    subnets        = local.subnets
    securityGroups = local.tasks_sg
    assignPublicIp = "DISABLED"
  }
}

output "secrets_to_fill" {
  description = "Every Secrets Manager entry this stack created EMPTY: name → ARN. Put a value in each before the first task starts."
  value       = { for k, s in aws_secretsmanager_secret.app : s.name => s.arn }
}

output "execution_role_arns" {
  value = { for k, r in aws_iam_role.exec : k => r.arn }
}

output "task_role_arns" {
  value = { for k, r in aws_iam_role.task : k => r.arn }
}

output "images" {
  description = "The image each task runs (repo@digest or repo:tag)."
  value       = local.image
}
