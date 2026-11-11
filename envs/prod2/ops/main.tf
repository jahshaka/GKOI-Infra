# ops — the orchestrator's ONE way to run SQL on prod 2's RDS from the dev box (GKOIBuilder_AI
# scripts/session-tools/prod-psql.sh). RDS is private (VPC only), so the SQL runs INSIDE the VPC as a one-off Fargate
# task, the same RunTask + log-read pattern as db-restore and the rehearsal:
#
#   prod-psql.sh <cms|engine|fm> [-c SQL | -f FILE | < stdin]
#     → ecs run-task gkoi-prod2-ops-psql-<app>, the SQL as a container override (gzip + base64, ≤ ~7 KB)
#     → the task runs scripts/psql.sh: psql as the APP role (its own password secret), one transaction,
#       read only unless WRITE=1, statement + wall-clock timeouts, the result framed + base64 in its log
#     → the tool waits for STOPPED, reads the log stream, reassembles stdout / stderr, exits with psql's code
#
# One task definition per app so a container only ever holds ITS app's password (the shared execution role reads the
# three secrets; execution-role credentials never reach a container). NO task role: the container has no AWS
# credentials at all. Never the RDS master. The caller needs iam/gkoi-orchestrator-ops.json (repo root).

data "terraform_remote_state" "data" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/data/terraform.tfstate"
    region = "us-west-2"
  }
}

data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/compute/terraform.tfstate"
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
  region    = "us-west-2"
  data      = data.terraform_remote_state.data.outputs
  compute   = data.terraform_remote_state.compute.outputs
  repos     = data.terraform_remote_state.registry.outputs.repositories
  log_group = "/gkoi/prod2/ecs/ops-psql"

  # The compute stack created the app password secrets; their exact ARNs come from its state (a missing one fails
  # the plan here instead of a task at run time).
  pw_secret_arn = { for app, a in var.apps : app => local.compute.secrets_to_fill[a.pw_secret] }

  image = "${local.repos["ci-postgres"]}@${data.aws_ecr_image.postgres.image_digest}"
}

data "aws_ecr_image" "postgres" {
  repository_name = "gkoi/ci-postgres"
  image_tag       = var.postgres_image_tag
}

resource "aws_cloudwatch_log_group" "psql" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# =================================================================================================================
# The execution role (/gkoi/): pull the mirror, write the log, inject the three app passwords. No task role.
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

resource "aws_iam_role" "exec" {
  name               = "gkoi-prod2-exec-ops-psql"
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
    sid       = "EcrPullPostgresMirror"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = ["arn:aws:ecr:${local.region}:${var.account_id}:repository/gkoi/ci-postgres"]
  }
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.psql.arn}:*"]
  }
  statement {
    sid       = "AppPasswords"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = sort(values(local.pw_secret_arn))
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "ecs-execution"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}

# =================================================================================================================
# Task definitions gkoi-prod2-ops-psql-<app>: one container, psql as the app role.
# =================================================================================================================

resource "aws_ecs_task_definition" "psql" {
  for_each                 = var.apps
  family                   = "gkoi-prod2-ops-psql-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_size.cpu)
  memory                   = tostring(var.task_size.memory)
  execution_role_arn       = aws_iam_role.exec.arn

  container_definitions = jsonencode([{
    name       = "psql"
    image      = local.image
    essential  = true
    user       = "postgres" # the image's uid 70; writes only under /tmp
    entryPoint = ["/bin/sh", "-c"]
    command    = [file("${path.module}/scripts/psql.sh")]
    environment = [for k, v in {
      PGHOST       = local.data.db_endpoint
      PGPORT       = tostring(local.data.db_port)
      PGDATABASE   = each.value.db
      PGUSER       = each.value.role
      PGSSLMODE    = "require" # rds.force_ssl=1; verify-full needs the RDS CA bundle (as compute: README "TLS to RDS")
      MAX_SECONDS  = tostring(var.max_seconds)
      STATEMENT_MS = tostring(var.statement_ms)
      WRITE        = "0"
      FIELD_SEP    = "|"
    } : { name = k, value = v }]
    secrets = [{ name = "PGPASSWORD", valueFrom = local.pw_secret_arn[each.key] }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.psql.name
        awslogs-region        = local.region
        awslogs-stream-prefix = each.key # streams: <app>/psql/<task id>
      }
    }
  }])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = { Name = "gkoi-prod2-ops-psql-${each.key}", service = "ops-psql" }
}

# What prod-psql.sh needs to start a task (no secret in it).
resource "aws_ssm_parameter" "run_config" {
  name = "/gkoi/prod2/ops/psql-run-config"
  type = "String"
  value = jsonencode({
    cluster        = local.compute.cluster_name
    log_group      = aws_cloudwatch_log_group.psql.name
    families       = { for k, t in aws_ecs_task_definition.psql : k => t.family }
    subnets        = local.compute.run_task_network.subnets
    securityGroups = local.compute.run_task_network.securityGroups
  })
}
