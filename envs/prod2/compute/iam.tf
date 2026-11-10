# Roles (path /gkoi/). One EXECUTION role per app (pull its own images, write its own log groups, read exactly the
# secrets its containers reference) and one TASK role per service (what the running code may call).

locals {
  ecr_arn = "arn:aws:ecr:${local.region}:${var.account_id}:repository/gkoi"
  log_arn = "arn:aws:logs:${local.region}:${var.account_id}:log-group:/gkoi/prod2/ecs"

  exec_apps = {
    cms = {
      repos   = ["cms-server", "cms-nginx"]
      logs    = ["cms-server", "cms-nginx", "cms-migrate"]
      secrets = [for k in distinct(concat(values(var.cms_server_secret_env), values(var.cms_nginx_secret_env))) : local.secret_arn[k]]
    }
    engine = {
      repos   = ["engine-api", "engine-worker", "engine-edge"]
      logs    = ["engine-api", "engine-edge", "engine-worker", "engine-migrate"]
      secrets = concat([for k in distinct(values(var.engine_secret_env)) : local.secret_arn[k]], [data.aws_secretsmanager_secret.live_origin.arn])
    }
    fm = {
      repos   = ["fm-api", "fm-worker", "fm-web"]
      logs    = ["fm-api", "fm-worker", "fm-web", "fm-migrate"]
      secrets = [for k in distinct(values(var.fm_secret_env)) : local.secret_arn[k]]
    }
  }
}

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

# --- execution roles ---------------------------------------------------------------------------------------------

resource "aws_iam_role" "exec" {
  for_each           = local.exec_apps
  name               = "gkoi-prod2-exec-${each.key}"
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "exec" {
  for_each = local.exec_apps

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPullOwnRepos"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [for r in each.value.repos : "${local.ecr_arn}/${r}"]
  }
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for g in each.value.logs : "${local.log_arn}/${g}:*"]
  }
  statement {
    sid       = "OwnSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = each.value.secrets
  }
}

resource "aws_iam_role_policy" "exec" {
  for_each = local.exec_apps
  name     = "ecs-execution"
  role     = aws_iam_role.exec[each.key].id
  policy   = data.aws_iam_policy_document.exec[each.key].json
}

# --- task roles --------------------------------------------------------------------------------------------------

locals {
  task_roles = toset(["cms", "engine-api", "engine-worker", "fm-api", "fm-worker", "fm-web", "migrate"])

  vod_buckets = distinct(concat([var.engine_vod_bucket], var.engine_extra_vod_buckets))
}

resource "aws_iam_role" "task" {
  for_each           = local.task_roles
  name               = "gkoi-prod2-task-${each.key}"
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ECS Exec (the rehearsal's shell into a task): every task role.
data "aws_iam_policy_document" "exec_command" {
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "exec_command" {
  for_each = local.task_roles
  name     = "ecs-exec"
  role     = aws_iam_role.task[each.key].id
  policy   = data.aws_iam_policy_document.exec_command.json
}

# CMS: the content file system, through its access point only.
data "aws_iam_policy_document" "cms" {
  statement {
    sid       = "EfsContent"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [local.data.efs_arn]
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [local.data.efs_cms_content_access_point_arn]
    }
  }
}

resource "aws_iam_role_policy" "cms" {
  name   = "cms-content"
  role   = aws_iam_role.task["cms"].id
  policy = data.aws_iam_policy_document.cms.json
}

# Engine api + worker: the recordings buckets (D3: no static keys — the SDK default chain = this role), the VOD
# distribution's invalidations, and the A7 metric namespace.
data "aws_iam_policy_document" "engine" {
  statement {
    sid       = "VodBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [for b in local.vod_buckets : "arn:aws:s3:::${b}"]
  }
  statement {
    sid = "VodObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [for b in local.vod_buckets : "arn:aws:s3:::${b}/*"]
  }
  dynamic "statement" {
    for_each = length(var.engine_cloudfront_distribution_ids) > 0 ? [1] : []
    content {
      sid       = "VodInvalidation"
      actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
      resources = [for d in var.engine_cloudfront_distribution_ids : "arn:aws:cloudfront::${var.account_id}:distribution/${d}"]
    }
  }
  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.engine_metrics_namespace]
    }
  }
}

resource "aws_iam_role_policy" "engine" {
  for_each = toset(["engine-api", "engine-worker"])
  name     = "engine-media"
  role     = aws_iam_role.task[each.key].id
  policy   = data.aws_iam_policy_document.engine.json
}

# File manager api + worker: the assets bucket (presigns are signed with this role's session keys).
data "aws_iam_policy_document" "fm" {
  statement {
    sid       = "AssetsBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads", "s3:GetBucketCors"]
    resources = ["arn:aws:s3:::${var.fm_assets_bucket}"]
  }
  statement {
    sid = "AssetsObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["arn:aws:s3:::${var.fm_assets_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "fm" {
  for_each = toset(["fm-api", "fm-worker"])
  name     = "fm-assets"
  role     = aws_iam_role.task[each.key].id
  policy   = data.aws_iam_policy_document.fm.json
}
