# Stage P6 — game: the War Room GAME servers on EC2, one ASG (min/max 1) per enabled region of var.game_regions
# (usw2 / euc1 / use1 on, apne1 defined + off), each box running the War Room's own hosting tool ops/warroom-game
# (GKOIBuilder_AI) — the same source.zip CodeBuild built the image from — wrapped by box/game-bootstrap.sh.
# README.md has the order, the use1 bring-up, the one-at-a-time replacement of usw2 + euc1 and the rollback.

module "regions" {
  source = "../../../modules/regions"
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/network/terraform.tfstate"
    region = "us-west-2"
  }
}

data "terraform_remote_state" "observability" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/observability/terraform.tfstate"
    region = "us-west-2"
  }
}

locals {
  net = data.terraform_remote_state.network.outputs
  obs = data.terraform_remote_state.observability.outputs

  # Enabled = asked for here AND the region is enabled in the catalogue (its VPC exists).
  asked   = { for k, v in var.game_regions : k => v if v.enabled }
  enabled = { for k, v in local.asked : k => v if contains(keys(module.regions.enabled), k) }

  # ---- the War Room release (tools/gkoi-release warroom-game <tag> wrote it) ---------------------------------------
  release_file = var.warroom_release_file != "" ? var.warroom_release_file : "${path.module}/../releases/warroom-game.json"
  release_doc  = fileexists(local.release_file) ? jsondecode(file(local.release_file)) : null
  release = var.warroom_release != null ? var.warroom_release : (local.release_doc == null ? null : {
    tag           = local.release_doc.tag
    commit        = local.release_doc.commit
    source_sha256 = local.release_doc.source_sha256
    digest        = local.release_doc.images["warroom-game"].digest
  })
  release_tag    = try(local.release.tag, "")
  release_digest = try(local.release.digest, "")

  # The tool = the release's own source.zip (git archive of ops/warroom-game at the commit the image was built from),
  # unless a tool-only zip is named.
  tool = var.warroom_tool_override != null ? {
    s3_key = var.warroom_tool_override.s3_key
    sha256 = var.warroom_tool_override.sha256
    commit = var.warroom_tool_override.commit
    } : {
    s3_key = "warroom-game/${local.release_tag}/source.zip"
    sha256 = try(local.release.source_sha256, "")
    commit = try(local.release.commit, "")
  }

  # ---- the box bundle: every file of box/ except the user-data template, at STABLE keys (an in-place update, never a
  # delete); the config carries each file's sha256 and the box refuses a file that does not match it.
  bundle_files  = sort([for f in fileset("${path.module}/box", "*") : f if !endswith(f, ".tftpl")])
  bundle_sha    = { for f in local.bundle_files : f => filesha256("${path.module}/box/${f}") }
  bundle_hash   = substr(sha256(join("\n", [for f in local.bundle_files : "${f} ${local.bundle_sha[f]}"])), 0, 16)
  bundle_prefix = "${var.bundle_prefix}/"

  # ---- names --------------------------------------------------------------------------------------------------------
  names = {
    for k, v in local.enabled : k => {
      rehearsal = [coalesce(v.rehearsal_matchd_host, "game-${k}-p2.gkoi.com"), coalesce(v.rehearsal_gateway_host, "gw-${k}-p2.gkoi.com")]
      live      = [coalesce(v.live_matchd_host, "game-${k}.gkoi.com"), coalesce(v.live_gateway_host, "gw-${k}.gkoi.com")]
    }
  }
  serving = { for k, v in local.enabled : k => v.serve_live_names ? local.names[k].live : local.names[k].rehearsal }

  ticket_secret_arn = merge(
    { for k, v in local.enabled : k => null },
    { for k, s in data.aws_secretsmanager_secret.ticket : k => s.arn },
  )

  # ---- per-region config (the SSM parameter's body; the module adds the EIP + ASG facts) ------------------------
  config = {
    for k, v in local.enabled : k => {
      v      = 1
      key    = k
      region = module.regions.all[k].region
      # the region's files in the War Room tool: ops.<warroom_env>.env + config/matchd.<warroom_env>.json
      warroom_env  = "beta-${k}"
      matchd_host  = local.serving[k][0]
      gateway_host = local.serving[k][1]
      matchd_port  = var.matchd_port
      gateway_port = var.gateway_port
      names        = local.names[k]
      acme_staging = var.acme_staging
      image = {
        tag      = local.release_tag
        registry = "${var.account_id}.dkr.ecr.${module.regions.all[k].region}.amazonaws.com"
        ref      = "${var.account_id}.dkr.ecr.${module.regions.all[k].region}.amazonaws.com/gkoi/warroom-game@${local.release_digest}"
      }
      tool = merge(local.tool, { bucket = var.bundle_bucket, region = "us-west-2" })
      bundle = {
        bucket = var.bundle_bucket
        region = "us-west-2"
        prefix = local.bundle_prefix
        files  = local.bundle_sha
        # a reference, so the config (and through it the ASG) waits for the uploads
        uploaded = length([for o in aws_s3_object.bundle : o.key])
      }
      secrets_region = "us-west-2"
      secrets = {
        match_server_key = local.match_server_key_arn
        ticket_key       = local.ticket_secret_arn[k]
      }
      cw                = { namespace = var.cw_namespace, log_prefix = "/gkoi/prod2/game/${k}", metrics_log_group = "/gkoi/prod2/game/${k}/metrics" }
      drain_max_minutes = var.drain_max_minutes
    }
  }

  user_data = {
    for k, v in local.enabled : k => templatefile("${path.module}/box/user-data.sh.tftpl", {
      region       = module.regions.all[k].region
      config_param = "/gkoi/prod2/game/${k}/config"
    })
  }

  live_records = { for k, v in local.enabled : k => v.manage_live_records ? local.names[k].live : [] }
  acme_names   = { for k, v in local.enabled : k => distinct(concat(local.names[k].rehearsal, local.names[k].live)) }
  secret_arns  = { for k, v in local.enabled : k => compact([local.match_server_key_arn, local.ticket_secret_arn[k]]) }

  bundle_object_arns = [
    "arn:aws:s3:::${var.bundle_bucket}/${var.bundle_prefix}/*",
    "arn:aws:s3:::${var.bundle_bucket}/warroom-game/*/source.zip",
    "arn:aws:s3:::${var.bundle_bucket}/warroom-game/tool/*",
  ]

  match_server_key_arn = aws_secretsmanager_secret.match_server_key.arn
}

# The plan stops here, naming what is missing, before anything is created.
resource "terraform_data" "preflight" {
  input = local.bundle_hash
  lifecycle {
    precondition {
      condition     = local.release != null
      error_message = "No envs/prod2/releases/warroom-game.json: run `tools/gkoi-release warroom-game <tag>` (e.g. 1.0.15.3.3-h6) and commit the file first — the boxes pull gkoi/warroom-game by its digest."
    }
    precondition {
      condition     = can(regex("^sha256:[0-9a-f]{64}$", local.release_digest)) && can(regex("^[0-9]+(\\.[0-9]+){2,4}[a-z]?(-h[0-9]+)?$", local.release_tag))
      error_message = "releases/warroom-game.json: no War Room tag / gkoi/warroom-game digest."
    }
    precondition {
      condition     = can(regex("^[0-9a-f]{64}$", local.tool.sha256)) && can(regex("^[0-9a-f]{40}$", local.tool.commit))
      error_message = "The War Room tool zip has no sha256 / commit (releases/warroom-game.json source_sha256 + commit, or warroom_tool_override)."
    }
    precondition {
      condition     = length(local.enabled) == length(local.asked)
      error_message = "A game region is enabled here but paused in modules/regions (no VPC): ${join(", ", [for k, v in local.asked : k if !contains(keys(module.regions.enabled), k)])}."
    }
  }
}

# --- the image in each box region's ECR (registry replication gkoi/ → euc1 + use1; a missing replica stops the plan) ---

data "aws_ecr_image" "game_usw2" {
  count           = contains(keys(local.enabled), "usw2") && local.release != null ? 1 : 0
  repository_name = "gkoi/warroom-game"
  image_digest    = local.release_digest
}

data "aws_ecr_image" "game_euc1" {
  count           = contains(keys(local.enabled), "euc1") && local.release != null ? 1 : 0
  provider        = aws.euc1
  repository_name = "gkoi/warroom-game"
  image_digest    = local.release_digest
}

data "aws_ecr_image" "game_use1" {
  count           = contains(keys(local.enabled), "use1") && local.release != null ? 1 : 0
  provider        = aws.use1
  repository_name = "gkoi/warroom-game"
  image_digest    = local.release_digest
}

data "aws_ecr_image" "game_apne1" {
  count           = contains(keys(local.enabled), "apne1") && local.release != null ? 1 : 0
  provider        = aws.apne1
  repository_name = "gkoi/warroom-game"
  image_digest    = local.release_digest
}

# --- the secrets (us-west-2; values are NEVER in Terraform: put them with the CLI — README "Secrets") -----------

resource "aws_secretsmanager_secret" "match_server_key" {
  name                    = var.match_server_key_secret
  description             = "GKOI prod2 game boxes: our match-server key (gk_..., invites:read + plays:write) as matchd key_file text"
  recovery_window_in_days = 7
}

data "aws_secretsmanager_secret" "ticket" {
  for_each = { for k, v in local.enabled : k => v.ticket_key_secret if v.ticket_key_secret != null }
  name     = each.value
}

# --- the box bundle (box/*: the bootstrap wrapper, roll, the lifecycle watcher, the CloudWatch templates) ---------

resource "aws_s3_object" "bundle" {
  for_each     = toset(local.bundle_files)
  bucket       = var.bundle_bucket
  key          = "${local.bundle_prefix}${each.value}"
  source       = "${path.module}/box/${each.value}"
  etag         = filemd5("${path.module}/box/${each.value}")
  content_type = "text/plain"
}

# --- one box per enabled region ------------------------------------------------------------------------------------

module "box_usw2" {
  source = "../../../modules/game-box"
  count  = contains(keys(local.enabled), "usw2") ? 1 : 0

  key                         = "usw2"
  region                      = module.regions.all.usw2.region
  account_id                  = var.account_id
  vpc_id                      = local.net.regions.usw2.vpc_id
  public_subnet_ids           = local.net.regions.usw2.public_subnet_ids
  instance_type               = coalesce(local.enabled.usw2.instance_type, var.default_instance_type)
  cpu_credits                 = local.enabled.usw2.cpu_credits
  root_volume_gib             = local.enabled.usw2.root_volume_gib
  ami_ssm_parameter           = var.ami_ssm_parameter
  min_size                    = local.enabled.usw2.min_size
  max_size                    = local.enabled.usw2.max_size
  desired_capacity            = local.enabled.usw2.desired_capacity
  matchd_port                 = var.matchd_port
  gateway_port                = var.gateway_port
  ingress_cidrs               = var.ingress_cidrs
  rehearsal_records           = local.names.usw2.rehearsal
  live_records                = local.live_records.usw2
  zone_id                     = var.zone_id
  acme_names                  = local.acme_names.usw2
  secret_arns                 = local.secret_arns.usw2
  bundle_object_arns          = local.bundle_object_arns
  ecr_repositories            = ["gkoi/warroom-game"]
  alarm_topic_arn             = try(local.obs.alerts_topic_arns.usw2, null)
  lifecycle_heartbeat_seconds = var.lifecycle_heartbeat_seconds
  cw_namespace                = var.cw_namespace
  metrics_log_group           = local.config.usw2.cw.metrics_log_group
  config                      = merge(local.config.usw2, { image_checked = try(data.aws_ecr_image.game_usw2[0].image_digest, null) })
  user_data                   = local.user_data.usw2
}

module "box_euc1" {
  source    = "../../../modules/game-box"
  count     = contains(keys(local.enabled), "euc1") ? 1 : 0
  providers = { aws = aws.euc1 }

  key                         = "euc1"
  region                      = module.regions.all.euc1.region
  account_id                  = var.account_id
  vpc_id                      = local.net.regions.euc1.vpc_id
  public_subnet_ids           = local.net.regions.euc1.public_subnet_ids
  instance_type               = coalesce(local.enabled.euc1.instance_type, var.default_instance_type)
  cpu_credits                 = local.enabled.euc1.cpu_credits
  root_volume_gib             = local.enabled.euc1.root_volume_gib
  ami_ssm_parameter           = var.ami_ssm_parameter
  min_size                    = local.enabled.euc1.min_size
  max_size                    = local.enabled.euc1.max_size
  desired_capacity            = local.enabled.euc1.desired_capacity
  matchd_port                 = var.matchd_port
  gateway_port                = var.gateway_port
  ingress_cidrs               = var.ingress_cidrs
  rehearsal_records           = local.names.euc1.rehearsal
  live_records                = local.live_records.euc1
  zone_id                     = var.zone_id
  acme_names                  = local.acme_names.euc1
  secret_arns                 = local.secret_arns.euc1
  bundle_object_arns          = local.bundle_object_arns
  ecr_repositories            = ["gkoi/warroom-game"]
  alarm_topic_arn             = try(local.obs.alerts_topic_arns.euc1, null)
  lifecycle_heartbeat_seconds = var.lifecycle_heartbeat_seconds
  cw_namespace                = var.cw_namespace
  metrics_log_group           = local.config.euc1.cw.metrics_log_group
  config                      = merge(local.config.euc1, { image_checked = try(data.aws_ecr_image.game_euc1[0].image_digest, null) })
  user_data                   = local.user_data.euc1
}

module "box_use1" {
  source    = "../../../modules/game-box"
  count     = contains(keys(local.enabled), "use1") ? 1 : 0
  providers = { aws = aws.use1 }

  key                         = "use1"
  region                      = module.regions.all.use1.region
  account_id                  = var.account_id
  vpc_id                      = local.net.regions.use1.vpc_id
  public_subnet_ids           = local.net.regions.use1.public_subnet_ids
  instance_type               = coalesce(local.enabled.use1.instance_type, var.default_instance_type)
  cpu_credits                 = local.enabled.use1.cpu_credits
  root_volume_gib             = local.enabled.use1.root_volume_gib
  ami_ssm_parameter           = var.ami_ssm_parameter
  min_size                    = local.enabled.use1.min_size
  max_size                    = local.enabled.use1.max_size
  desired_capacity            = local.enabled.use1.desired_capacity
  matchd_port                 = var.matchd_port
  gateway_port                = var.gateway_port
  ingress_cidrs               = var.ingress_cidrs
  rehearsal_records           = local.names.use1.rehearsal
  live_records                = local.live_records.use1
  zone_id                     = var.zone_id
  acme_names                  = local.acme_names.use1
  secret_arns                 = local.secret_arns.use1
  bundle_object_arns          = local.bundle_object_arns
  ecr_repositories            = ["gkoi/warroom-game"]
  alarm_topic_arn             = try(local.obs.alerts_topic_arns.use1, null)
  lifecycle_heartbeat_seconds = var.lifecycle_heartbeat_seconds
  cw_namespace                = var.cw_namespace
  metrics_log_group           = local.config.use1.cw.metrics_log_group
  config                      = merge(local.config.use1, { image_checked = try(data.aws_ecr_image.game_use1[0].image_digest, null) })
  user_data                   = local.user_data.use1
}

# Tokyo — DISABLED by default (game_regions.apne1.enabled = false; modules/regions pauses apne1). To enable: the
# catalogue + network + observability first (modules/regions README), add ap-northeast-1 to the registry stack's ECR
# replication, the EC2 vCPU quota, then game_regions.apne1.enabled = true.
module "box_apne1" {
  source    = "../../../modules/game-box"
  count     = contains(keys(local.enabled), "apne1") ? 1 : 0
  providers = { aws = aws.apne1 }

  key                         = "apne1"
  region                      = module.regions.all.apne1.region
  account_id                  = var.account_id
  vpc_id                      = local.net.regions.apne1.vpc_id
  public_subnet_ids           = local.net.regions.apne1.public_subnet_ids
  instance_type               = coalesce(local.enabled.apne1.instance_type, var.default_instance_type)
  cpu_credits                 = local.enabled.apne1.cpu_credits
  root_volume_gib             = local.enabled.apne1.root_volume_gib
  ami_ssm_parameter           = var.ami_ssm_parameter
  min_size                    = local.enabled.apne1.min_size
  max_size                    = local.enabled.apne1.max_size
  desired_capacity            = local.enabled.apne1.desired_capacity
  matchd_port                 = var.matchd_port
  gateway_port                = var.gateway_port
  ingress_cidrs               = var.ingress_cidrs
  rehearsal_records           = local.names.apne1.rehearsal
  live_records                = local.live_records.apne1
  zone_id                     = var.zone_id
  acme_names                  = local.acme_names.apne1
  secret_arns                 = local.secret_arns.apne1
  bundle_object_arns          = local.bundle_object_arns
  ecr_repositories            = ["gkoi/warroom-game"]
  alarm_topic_arn             = try(local.obs.alerts_topic_arns.apne1, null)
  lifecycle_heartbeat_seconds = var.lifecycle_heartbeat_seconds
  cw_namespace                = var.cw_namespace
  metrics_log_group           = local.config.apne1.cw.metrics_log_group
  config                      = merge(local.config.apne1, { image_checked = try(data.aws_ecr_image.game_apne1[0].image_digest, null) })
  user_data                   = local.user_data.apne1
}
