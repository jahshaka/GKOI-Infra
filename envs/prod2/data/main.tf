# Stage 1 — data: RDS PostgreSQL 16 (single-AZ, operator ruling), ElastiCache Valkey (one node, noeviction per G3,
# TLS + auth token), EFS for the CMS content. Only the ECS tasks' SG (from the network stack) reaches any of them.

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/network/terraform.tfstate"
    region = "us-west-2"
  }
}

locals {
  net      = data.terraform_remote_state.network.outputs
  tasks_sg = local.net.ecs_tasks_security_group_id
  db_id    = "gkoi-prod2-pg"
}

# =================================================================================================================
# RDS PostgreSQL 16
# =================================================================================================================

resource "aws_db_subnet_group" "pg" {
  name       = "gkoi-prod2-pg"
  subnet_ids = local.net.home_private_subnet_ids
}

resource "aws_security_group" "pg" {
  name        = "gkoi-prod2-pg"
  description = "RDS Postgres: 5432 from the ECS tasks only"
  vpc_id      = local.net.home_vpc_id
  tags        = { Name = "gkoi-prod2-pg" }
}

resource "aws_vpc_security_group_ingress_rule" "pg_from_tasks" {
  security_group_id            = aws_security_group.pg.id
  description                  = "Postgres from the ECS tasks"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = local.tasks_sg
}

resource "aws_db_parameter_group" "pg16" {
  name        = "gkoi-prod2-pg16"
  family      = "postgres16"
  description = "GKOI prod2: TLS required, slow-statement and lock logging"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.db_log_min_duration_ms)
  }
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }
  parameter {
    name  = "log_temp_files"
    value = "10240" # kB: log temp files over 10 MB
  }
  parameter {
    name  = "log_autovacuum_min_duration"
    value = "10000"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Pre-created so the retention is ours (RDS would create them with "never expire").
resource "aws_cloudwatch_log_group" "pg" {
  for_each          = toset(["postgresql", "upgrade"])
  name              = "/aws/rds/instance/${local.db_id}/${each.key}"
  retention_in_days = 30
}

resource "aws_db_instance" "pg" {
  identifier     = local.db_id
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # Databases (cms / engine / fm) and their owner roles are created by the restore (P1 rehearsal), not here.
  username                    = var.db_master_username
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.pg.name
  vpc_security_group_ids = [aws_security_group.pg.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az
  parameter_group_name   = aws_db_parameter_group.pg16.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = var.db_backup_window
  maintenance_window         = var.db_maintenance_window
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = false

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.db_id}-final"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = local.db_id }

  depends_on = [aws_cloudwatch_log_group.pg]
}

# =================================================================================================================
# ElastiCache Valkey (one node)
# =================================================================================================================

resource "aws_elasticache_subnet_group" "valkey" {
  name       = "gkoi-prod2-valkey"
  subnet_ids = local.net.home_private_subnet_ids
}

resource "aws_security_group" "valkey" {
  name        = "gkoi-prod2-valkey"
  description = "Valkey: 6379 from the ECS tasks only"
  vpc_id      = local.net.home_vpc_id
  tags        = { Name = "gkoi-prod2-valkey" }
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_tasks" {
  security_group_id            = aws_security_group.valkey.id
  description                  = "Valkey from the ECS tasks"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = local.tasks_sg
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_peers" {
  for_each          = toset(var.valkey_peer_cidrs != null ? var.valkey_peer_cidrs : values(local.net.edge_cidrs))
  security_group_id = aws_security_group.valkey.id
  description       = "Valkey from a peered VPC"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
  cidr_ipv4         = each.value
}

resource "aws_elasticache_parameter_group" "valkey" {
  name        = "gkoi-prod2-valkey"
  family      = var.valkey_parameter_family
  description = "GKOI prod2: noeviction (G3, REDIS_REQUIRE_NOEVICTION)"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

# Printable, no '@', '"' or '/': alphanumerics only, so it also needs no escaping inside a URL.
resource "random_password" "valkey_auth" {
  length  = 64
  special = false
}

resource "aws_cloudwatch_log_group" "valkey_slow" {
  name              = "/gkoi/prod2/valkey/slow-log"
  retention_in_days = 30
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "gkoi-prod2-valkey"
  description          = "GKOI prod2 Valkey (engine + FM, separate db/prefix)"
  engine               = "valkey"
  engine_version       = var.valkey_engine_version
  node_type            = var.valkey_node_type
  port                 = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  parameter_group_name = aws_elasticache_parameter_group.valkey.name
  subnet_group_name    = aws_elasticache_subnet_group.valkey.name
  security_group_ids   = [aws_security_group.valkey.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.valkey_auth.result

  snapshot_retention_limit   = 1
  snapshot_window            = "09:00-10:00"
  maintenance_window         = "tue:12:00-tue:13:00"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.valkey_slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }
}

resource "aws_secretsmanager_secret" "valkey" {
  name                    = "gkoi/prod2/valkey"
  description             = "Valkey auth token + TLS connection URL (rediss://). Managed by Terraform (data stack)."
  recovery_window_in_days = var.secret_recovery_days
}

resource "aws_secretsmanager_secret_version" "valkey" {
  secret_id = aws_secretsmanager_secret.valkey.id
  secret_string = jsonencode({
    auth_token = random_password.valkey_auth.result
    host       = aws_elasticache_replication_group.valkey.primary_endpoint_address
    port       = 6379
    tls        = true
    url        = "rediss://:${random_password.valkey_auth.result}@${aws_elasticache_replication_group.valkey.primary_endpoint_address}:6379"
  })
}

# =================================================================================================================
# EFS — the CMS content (uid/gid 33 = www-data)
# =================================================================================================================

resource "aws_efs_file_system" "cms" {
  creation_token   = "gkoi-prod2-cms"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = var.efs_throughput_mode
  tags             = { Name = "gkoi-prod2-cms" }
}

resource "aws_efs_backup_policy" "cms" {
  file_system_id = aws_efs_file_system.cms.id
  backup_policy {
    status = var.efs_backup ? "ENABLED" : "DISABLED"
  }
}

resource "aws_security_group" "efs" {
  name        = "gkoi-prod2-efs"
  description = "EFS: NFS from the ECS tasks only"
  vpc_id      = local.net.home_vpc_id
  tags        = { Name = "gkoi-prod2-efs" }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_tasks" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the ECS tasks"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = local.tasks_sg
}

resource "aws_efs_mount_target" "cms" {
  count           = length(local.net.home_private_subnet_ids)
  file_system_id  = aws_efs_file_system.cms.id
  subnet_id       = local.net.home_private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "cms_content" {
  file_system_id = aws_efs_file_system.cms.id

  posix_user {
    uid = 33
    gid = 33
  }

  root_directory {
    path = "/cms-content"
    creation_info {
      owner_uid   = 33
      owner_gid   = 33
      permissions = "0755"
    }
  }

  tags = { Name = "gkoi-prod2-cms-content" }
}

# TLS only; mounts only through a mount target. (No ClientRootAccess: clients act as the access point's uid 33.)
data "aws_iam_policy_document" "efs" {
  statement {
    sid     = "MountViaTargets"
    effect  = "Allow"
    actions = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    resources = [aws_efs_file_system.cms.arn]
    condition {
      test     = "Bool"
      variable = "elasticfilesystem:AccessedViaMountTarget"
      values   = ["true"]
    }
  }
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    resources = [aws_efs_file_system.cms.arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_efs_file_system_policy" "cms" {
  file_system_id = aws_efs_file_system.cms.id
  policy         = data.aws_iam_policy_document.efs.json
}
