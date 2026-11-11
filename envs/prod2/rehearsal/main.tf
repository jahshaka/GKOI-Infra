# rehearsal — the PRIVATE go-live rehearsal driver (README.md here): the one-off ECS task gkoi-prod2-rehearsal-driver
# that walks the GKOI Live app's path against the ECS engine in every media region and prints PASS/FAIL. Its own stack
# (as db-restore): it reads network, edge-alb, data, compute and media — the LAST of them — so no earlier stack reads
# it, and it can be destroyed after the window without touching compute.
#
#   tools/gkoi-rehearsal [--only usw2,euc1] [--seconds 60] [--parallel] [--dry-run]   (run-task + wait + the log)
#
# The gateway secret and the origin secrets reach ONLY the driver container (ECS secrets through the execution role);
# the task role can list the scratch bucket and nothing else. No secret value enters this state.

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/network/terraform.tfstate"
    region = "us-west-2"
  }
}

data "terraform_remote_state" "edge" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/edge-alb/terraform.tfstate"
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

data "terraform_remote_state" "compute" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/compute/terraform.tfstate"
    region = "us-west-2"
  }
}

data "terraform_remote_state" "media" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/media/terraform.tfstate"
    region = "us-west-2"
  }
}

module "regions" {
  source = "../../../modules/regions"
}

locals {
  region  = "us-west-2"
  family  = "gkoi-prod2-rehearsal-driver"
  edge    = data.terraform_remote_state.edge.outputs
  data    = data.terraform_remote_state.data.outputs
  compute = data.terraform_remote_state.compute.outputs
  media   = data.terraform_remote_state.media.outputs

  scratch = try(local.data.rehearsal_vods_bucket, null)
  boxes   = try(local.media.boxes, {})

  # What the driver tests: every box the media stack runs, under the names it serves NOW (the rehearsal names while
  # serve_live_names is off — media refuses rehearsal = true otherwise).
  driver_regions = [for k in sort(keys(local.boxes)) : {
    key        = k
    region     = module.regions.all[k].region
    streamHost = local.boxes[k].stream_host
    originHost = local.boxes[k].origin_host
  }]

  # The switches as the other stacks applied them (try: an older state has no such output = off).
  armed = {
    compute         = try(local.compute.rehearsal.enabled, false)
    media           = try(local.media.rehearsal.enabled, false)
    engine_bucket   = try(local.compute.rehearsal.engine_bucket, null)
    agents_bucket   = try(local.media.rehearsal.recordings_bucket, null)
    running         = try(local.compute.rehearsal.running, [])
    scratch_matches = local.scratch != null && try(local.compute.rehearsal.engine_bucket, "") == try(local.scratch.name, "-") && try(local.media.rehearsal.recordings_bucket, "") == try(local.scratch.name, "-")
  }

  driver_js = file("${path.module}/driver/driver.mjs")

  driver_env = {
    DRIVER_MJS_GZ_B64     = base64gzip(local.driver_js)
    DRIVER_SHA256         = sha256(local.driver_js)
    ENGINE_URL            = var.engine_url
    ENGINE_CONNECT_HOST   = try(local.edge.alb_dns_name, "")
    REGIONS               = jsonencode(local.driver_regions)
    CMS_USER_ID           = var.cms_user_id
    PUBLISH_SECONDS       = tostring(var.publish_seconds)
    VIDEO_KBPS            = tostring(var.video_kbps)
    SCRATCH_BUCKET        = try(local.scratch.name, "")
    SCRATCH_BUCKET_REGION = try(local.scratch.region, local.region)
  }

  gateway_secret_arn = data.aws_secretsmanager_secret.gateway.arn
  origin_value_from = {
    for k, s in data.aws_secretsmanager_secret.origin_verify : k => (
      var.origin_verify_secret_json_key == "" ? s.arn : "${s.arn}:${var.origin_verify_secret_json_key}::"
    )
  }

  container = {
    name        = "driver"
    image       = var.driver_image
    essential   = true
    entryPoint  = ["/bin/sh", "-c"]
    command     = [file("${path.module}/driver/entrypoint.sh")]
    environment = [for k in sort(keys(local.driver_env)) : { name = k, value = local.driver_env[k] }]
    secrets = concat(
      [{ name = "GATEWAY_SHARED_SECRET", valueFrom = local.gateway_secret_arn }],
      [for k in sort(keys(local.origin_value_from)) : { name = "ORIGIN_VERIFY_${upper(k)}", valueFrom = local.origin_value_from[k] }],
    )
    stopTimeout = 30
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.driver.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "driver" # streams: driver/driver/<task id>
      }
    }
  }
  container_definitions = jsonencode([local.container])
}

# The secrets' METADATA only (ARNs); values never enter this state.
data "aws_secretsmanager_secret" "gateway" {
  name = var.gateway_secret_name
}

data "aws_secretsmanager_secret" "origin_verify" {
  for_each = local.boxes
  name     = format(var.origin_verify_secret_pattern, each.key)
}

resource "terraform_data" "preflight" {
  input = sha256(local.container_definitions)
  lifecycle {
    precondition {
      condition     = local.scratch != null
      error_message = "No scratch bucket: apply the data stack (output rehearsal_vods_bucket) first."
    }
    precondition {
      condition     = length(local.driver_regions) > 0
      error_message = "The media stack reports no box (output boxes): apply media first."
    }
    precondition {
      condition     = try(local.edge.alb_dns_name, "") != ""
      error_message = "edge-alb has no alb_dns_name output."
    }
    precondition {
      condition     = length(local.container_definitions) < 60000
      error_message = "The container definition is ${length(local.container_definitions)} bytes (ECS: 64 KiB per task definition) — shrink driver.mjs."
    }
  }
}

# Warn (never block: the task definition may exist while the switches are off) when a run would not be a rehearsal.
check "rehearsal_armed" {
  assert {
    condition     = local.armed.compute && local.armed.media && local.armed.scratch_matches
    error_message = "The rehearsal is NOT armed (compute rehearsal=${local.armed.compute}, media rehearsal=${local.armed.media}, both on the scratch bucket=${local.armed.scratch_matches}): tools/gkoi-rehearsal refuses to start the driver until it is."
  }
}

# =================================================================================================================
# Log group + roles (/gkoi/)
# =================================================================================================================

resource "aws_cloudwatch_log_group" "driver" {
  name              = "/gkoi/prod2/ecs/rehearsal-driver"
  retention_in_days = var.log_retention_days
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

# Execution: write its log group, inject the gateway + origin secrets. The image is ECR Public: no pull rights needed.
resource "aws_iam_role" "exec" {
  name               = "gkoi-prod2-exec-rehearsal-driver"
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "exec" {
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.driver.arn}:*"]
  }
  statement {
    sid       = "DriverSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = concat([local.gateway_secret_arn], [for k, s in data.aws_secretsmanager_secret.origin_verify : s.arn])
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "ecs-execution"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}

# Task: list the scratch bucket (the recording's objects) — nothing else, no write anywhere.
resource "aws_iam_role" "task" {
  name               = "gkoi-prod2-task-rehearsal-driver"
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "ListScratch"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${try(local.scratch.name, "none")}"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "rehearsal-driver"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# =================================================================================================================
# The task definition + what tools/gkoi-rehearsal needs to start it
# =================================================================================================================

resource "aws_ecs_task_definition" "driver" {
  family                   = local.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_size.cpu)
  memory                   = tostring(var.task_size.memory)
  execution_role_arn       = aws_iam_role.exec.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = local.container_definitions

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = { Name = local.family, service = "rehearsal-driver" }

  depends_on = [terraform_data.preflight]
}

locals {
  # No secret in it. tools/gkoi-rehearsal reads it from SSM, or from a file holding this stack's `run_config` output.
  run_config = {
    cluster        = local.compute.cluster_name
    family         = aws_ecs_task_definition.driver.family
    revision       = aws_ecs_task_definition.driver.revision
    container      = "driver"
    log_group      = aws_cloudwatch_log_group.driver.name
    subnets        = local.compute.run_task_network.subnets
    securityGroups = local.compute.run_task_network.securityGroups
    regions        = [for r in local.driver_regions : r.key]
    scratch_bucket = try(local.scratch.name, "")
    armed          = local.armed
  }
}

resource "aws_ssm_parameter" "run_config" {
  name  = "/gkoi/prod2/rehearsal/run-config"
  type  = "String"
  value = jsonencode(local.run_config)
}
