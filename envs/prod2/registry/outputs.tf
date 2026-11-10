output "repositories" {
  description = "name → repository URL (us-west-2)."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "replica_regions" {
  value = local.replica_regions
}

output "build_projects" {
  value = {
    for k, m in module.build : k => {
      project   = m.project_name
      role_arn  = m.role_arn
      log_group = m.log_group
    }
  }
}
