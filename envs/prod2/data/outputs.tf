output "db_instance_id" {
  value = aws_db_instance.pg.identifier
}

output "db_endpoint" {
  value = aws_db_instance.pg.address
}

output "db_port" {
  value = aws_db_instance.pg.port
}

output "db_master_secret_arn" {
  description = "The RDS-managed master password secret (rotation by RDS)."
  value       = aws_db_instance.pg.master_user_secret[0].secret_arn
}

output "db_security_group_id" {
  value = aws_security_group.pg.id
}

output "valkey_id" {
  value = aws_elasticache_replication_group.valkey.id
}

output "valkey_primary_endpoint" {
  value = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "valkey_secret_arn" {
  value = aws_secretsmanager_secret.valkey.arn
}

output "valkey_security_group_id" {
  value = aws_security_group.valkey.id
}

output "efs_id" {
  value = aws_efs_file_system.cms.id
}

output "efs_arn" {
  value = aws_efs_file_system.cms.arn
}

output "efs_cms_content_access_point_id" {
  value = aws_efs_access_point.cms_content.id
}

output "efs_cms_content_access_point_arn" {
  value = aws_efs_access_point.cms_content.arn
}
