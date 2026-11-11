output "run_config" {
  description = "What tools/gkoi-rehearsal needs (also in SSM /gkoi/prod2/rehearsal/run-config). No secret in it. Save it as JSON for `gkoi-rehearsal --config FILE` when SSM cannot be read."
  value       = local.run_config
}

output "run_task_request" {
  description = "The exact `aws ecs run-task --cli-input-json` request (all regions, the defaults). tools/gkoi-rehearsal --dry-run prints the same with its overrides."
  value = jsonencode({
    cluster              = local.run_config.cluster
    taskDefinition       = "${local.run_config.family}:${local.run_config.revision}"
    launchType           = "FARGATE"
    platformVersion      = "LATEST"
    count                = 1
    startedBy            = "gkoi-rehearsal"
    networkConfiguration = { awsvpcConfiguration = { subnets = local.run_config.subnets, securityGroups = local.run_config.securityGroups, assignPublicIp = "DISABLED" } }
  })
}

output "armed" {
  description = "Whether a run now is a rehearsal: compute + media rehearsal on, both on the scratch bucket, and which services run."
  value       = local.armed
}

output "driver_regions" {
  value = local.driver_regions
}

output "log_group" {
  value = aws_cloudwatch_log_group.driver.name
}

output "container_definition_bytes" {
  value = length(local.container_definitions)
}
