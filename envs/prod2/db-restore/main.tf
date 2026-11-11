# db-restore — the prod → RDS database move (P1 rehearsal, P3 engine + FM, P4 CMS). Its own stack (not compute):
# the compute plan stops in its preflight until every service image is released, and a restore must not wait on that.
#
#   tools/gkoi-db-dump <app>                 prod box → pg_dump -Fc → this box → s3://<transit>/<app>/<stamp>/<db>.dump
#   tools/gkoi-db-restore <app> <s3 key>     ecs run-task gkoi-prod2-db-restore-<app>: fetch (aws-cli) → restore (psql)
#
# One task definition per app, each with its OWN task role: that app's prefix in the transit bucket and that app's
# password secret only (an env override cannot reach another app). The RDS master (the RDS-managed secret) reaches only
# the restore container, through the shared execution role. Scripts: scripts/fetch.sh, scripts/restore.sh (inlined).

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/network/terraform.tfstate"
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

data "terraform_remote_state" "registry" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/registry/terraform.tfstate"
    region = "us-west-2"
  }
}

locals {
  region = "us-west-2"
  net    = data.terraform_remote_state.network.outputs
  data   = data.terraform_remote_state.data.outputs
  repos  = data.terraform_remote_state.registry.outputs.repositories

  log_group  = "/gkoi/prod2/ecs/db-restore"
  master_arn = local.data.db_master_secret_arn

  # Secrets Manager appends "-" + 6 random characters to a secret's ARN.
  pw_secret_arn = { for app, a in var.apps : app => "arn:aws:secretsmanager:${local.region}:${var.account_id}:secret:${a.pw_secret}-??????" }

  image = {
    postgres = "${local.repos["postgres"]}@${data.aws_ecr_image.postgres.image_digest}"
    aws_cli  = "${local.repos["aws-cli"]}@${data.aws_ecr_image.aws_cli.image_digest}"
  }
}

data "aws_ecr_image" "postgres" {
  repository_name = "gkoi/postgres"
  image_tag       = var.postgres_image_tag
}

data "aws_ecr_image" "aws_cli" {
  repository_name = "gkoi/aws-cli"
  image_tag       = var.awscli_image_tag
}

# =================================================================================================================
# The transit bucket: private, SSE-S3, TLS only, objects expire after transit_days.
# =================================================================================================================

resource "aws_s3_bucket" "transit" {
  bucket = var.transit_bucket
}

resource "aws_s3_bucket_public_access_block" "transit" {
  bucket                  = aws_s3_bucket.transit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "transit" {
  bucket = aws_s3_bucket.transit.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "transit" {
  bucket = aws_s3_bucket.transit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "transit" {
  bucket = aws_s3_bucket.transit.id
  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter {}
    expiration {
      days = var.transit_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "transit" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [aws_s3_bucket.transit.arn, "${aws_s3_bucket.transit.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "transit" {
  bucket     = aws_s3_bucket.transit.id
  policy     = data.aws_iam_policy_document.transit.json
  depends_on = [aws_s3_bucket_public_access_block.transit]
}

resource "aws_cloudwatch_log_group" "restore" {
  name              = local.log_group
  retention_in_days = 30
}

# =================================================================================================================
# Roles (/gkoi/)
# =================================================================================================================

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${local.region}:${var.account_id}:*"]
    }
  }
}

# Execution: pull the two mirrors, write the log group, inject the RDS master user/password into "restore".
resource "aws_iam_role" "exec" {
  name               = "gkoi-prod2-exec-db-restore"
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "exec" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPullMirrors"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = ["arn:aws:ecr:${local.region}:${var.account_id}:repository/gkoi/postgres", "arn:aws:ecr:${local.region}:${var.account_id}:repository/gkoi/aws-cli"]
  }
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.restore.arn}:*"]
  }
  statement {
    sid       = "RdsMasterSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.master_arn]
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "ecs-execution"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}

# Task, one per app: its dump prefix (read) and its password secret (read; write only with allow_generate_password).
resource "aws_iam_role" "task" {
  for_each           = var.apps
  name               = "gkoi-prod2-task-db-restore-${each.key}"
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task" {
  for_each = var.apps

  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.transit.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }
  statement {
    sid       = "ReadOwnDumps"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.transit.arn}/${each.key}/*"]
  }
  statement {
    sid       = "ReadOwnPassword"
    actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
    resources = [local.pw_secret_arn[each.key]]
  }
  dynamic "statement" {
    for_each = var.allow_generate_password ? [1] : []
    content {
      sid       = "FillOwnPassword"
      actions   = ["secretsmanager:PutSecretValue"]
      resources = [local.pw_secret_arn[each.key]]
    }
  }
  dynamic "statement" {
    for_each = var.allow_generate_password ? [1] : []
    content {
      sid       = "RandomPassword"
      actions   = ["secretsmanager:GetRandomPassword"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  for_each = var.apps
  name     = "db-restore"
  role     = aws_iam_role.task[each.key].id
  policy   = data.aws_iam_policy_document.task[each.key].json
}

# =================================================================================================================
# Task definitions gkoi-prod2-db-restore-<app>: fetch (one shot, must exit 0) → restore (essential: its exit = the task's)
# =================================================================================================================

locals {
  awslogs = { for app in keys(var.apps) : app => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.restore.name
      awslogs-region        = local.region
      awslogs-stream-prefix = app # streams: <app>/<container>/<task id>
    }
  } }

  containers = { for app, a in var.apps : app => [
    {
      name             = "fetch"
      image            = local.image.aws_cli
      essential        = false
      entryPoint       = ["/bin/bash", "-c"]
      command          = [file("${path.module}/scripts/fetch.sh")]
      environment      = [for k, v in { APP = app, BUCKET = aws_s3_bucket.transit.id, PW_SECRET_ID = a.pw_secret, GENERATE_PASSWORD = "0", WORK = "/work" } : { name = k, value = v }]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      logConfiguration = local.awslogs[app]
    },
    {
      name       = "restore"
      image      = local.image.postgres
      essential  = true
      entryPoint = ["/bin/sh", "-c"]
      command    = [file("${path.module}/scripts/restore.sh")]
      dependsOn  = [{ containerName = "fetch", condition = "SUCCESS" }]
      environment = [for k, v in {
        DB_NAME       = a.db
        DB_ROLE       = a.role
        PGHOST        = local.data.db_endpoint
        PGPORT        = tostring(local.data.db_port)
        PGSSLMODE     = "require"
        DB_LC_COLLATE = var.db_lc_collate
        DB_LC_CTYPE   = var.db_lc_ctype
        WORK          = "/work"
      } : { name = k, value = v }]
      secrets = [
        { name = "PGUSER", valueFrom = "${local.master_arn}:username::" },
        { name = "PGPASSWORD", valueFrom = "${local.master_arn}:password::" },
      ]
      mountPoints      = [{ sourceVolume = "work", containerPath = "/work", readOnly = false }]
      logConfiguration = local.awslogs[app]
    },
  ] }
}

resource "aws_ecs_task_definition" "restore" {
  for_each                 = var.apps
  family                   = "gkoi-prod2-db-restore-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_size.cpu)
  memory                   = tostring(var.task_size.memory)
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task[each.key].arn
  container_definitions    = jsonencode(local.containers[each.key])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "work" # task storage: gone with the task (the dump and the password file never outlive it)
  }

  tags = { Name = "gkoi-prod2-db-restore-${each.key}", service = "db-restore" }
}

# What tools/gkoi-db-restore needs to start a task (no secret in it).
resource "aws_ssm_parameter" "run_config" {
  name = "/gkoi/prod2/db-restore/run-config"
  type = "String"
  value = jsonencode({
    cluster        = var.cluster_name
    bucket         = aws_s3_bucket.transit.id
    log_group      = aws_cloudwatch_log_group.restore.name
    families       = { for k, t in aws_ecs_task_definition.restore : k => t.family }
    subnets        = local.net.home_private_subnet_ids
    securityGroups = [local.net.ecs_tasks_security_group_id]
  })
}
