# Stage P5 — media: the GKOI media boxes on EC2, one ASG (min/max 1) per enabled region of var.media_regions, each
# REGISTERING its pools with the engine (SPEC-ENGINE-DYNAMIC-REGIONS-V1 C1: MEDIA_BOX_INSTANCES, no static list), plus
# the private path to the engine api (internal-alb.tf) and the box's Valkey rule. README.md has the order, the
# rehearsal, the window and the rollback.

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

data "terraform_remote_state" "data" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/data/terraform.tfstate"
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
  net      = data.terraform_remote_state.network.outputs
  data     = data.terraform_remote_state.data.outputs
  obs      = data.terraform_remote_state.observability.outputs
  home_key = module.regions.home_key

  # Enabled = asked for here AND the region is enabled in the catalogue (its VPC exists).
  enabled = { for k, v in var.media_regions : k => v if v.enabled && contains(keys(module.regions.enabled), k) }

  # ---- the engine release (gkoi-release wrote it; the boxes pull the same digests the release recorded) ----------
  release = jsondecode(file("${path.module}/../releases/mikaido.json"))
  image_ref = {
    for n in ["media-agent", "mediamtx"] : n => lookup(var.images, n, try(local.release.images[n].digest, ""))
  }
  missing_images = [for n, v in local.image_ref : n if v == ""]
  engine_source = {
    tag    = local.release.tag
    commit = local.release.commit
    s3_uri = "s3://${var.bundle_bucket}/mikaido/${local.release.tag}/source.zip"
    sha256 = local.release.source_sha256
  }

  # ---- the box bundle: every file of box/ except the user-data template, at STABLE keys (a change is an in-place
  # update, never a delete — tools/tf-run.sh refuses deletes without ALLOW_DESTROY); the config carries each file's
  # sha256 and the box refuses a file that does not match it.
  bundle_files  = sort([for f in fileset("${path.module}/box", "*") : f if !endswith(f, ".tftpl")])
  bundle_sha    = { for f in local.bundle_files : f => filesha256("${path.module}/box/${f}") }
  bundle_hash   = substr(sha256(join("\n", [for f in local.bundle_files : "${f} ${local.bundle_sha[f]}"])), 0, 16)
  bundle_prefix = "${var.bundle_prefix}/"

  # ---- the engine's private api address -------------------------------------------------------------------------
  portal_internal_url = var.engine_internal_url_override != "" ? var.engine_internal_url_override : (
    var.create_engine_internal_alb ? "http://${aws_lb.engine_internal[0].dns_name}:3000" : ""
  )

  agent_env = merge({
    APP_ENV                   = "production"
    LOG_LEVEL                 = "info"
    ENGINE_HOME_REGION        = var.engine_home_region
    MK_POOL_API_USER          = "mkpool" # = prod's (compute env-defaults MK_POOL_API_USER)
    MK_POOL_REQUIRE_AUTH      = "1"
    MK_RECORDINGS_DISK_CAP_MB = "2048" # = the live box
    # G4/G6: every call to the api reuses its connection (Frankfurt paid a new TCP handshake per 5-s call: 290 vs 148 ms).
    # Below the internal ALB's 60 s idle timeout, as the api's own HTTP_KEEPALIVE_MS (55000).
    HTTP_KEEPALIVE_MS    = "55000"
    S3_ENDPOINT_INTERNAL = "https://s3.${var.recordings_bucket_region}.amazonaws.com"
    S3_ENDPOINT_PUBLIC   = "https://s3.${var.recordings_bucket_region}.amazonaws.com"
    S3_REGION            = var.recordings_bucket_region
    S3_BUCKET            = var.recordings_bucket
    # S3_ACCESS_KEY / S3_SECRET_KEY deliberately absent: the AWS SDK's default chain = the instance role (D3).
  }, length(var.extra_vod_buckets) > 0 ? { VOD_BUCKETS = jsonencode([for b in var.extra_vod_buckets : { bucket = b }]) } : {}, var.agent_env)

  # ---- per-region config (the SSM parameter's body; the module adds the EIP + ASG facts) ------------------------
  config = {
    for k, v in local.enabled : k => {
      v                   = 1
      key                 = k
      region              = module.regions.all[k].region
      home_region         = var.engine_home_region
      label               = v.label
      stream_host         = v.serve_live_names ? v.live_stream_host : v.rehearsal_stream_host
      origin_host         = v.serve_live_names ? v.live_origin_host : v.rehearsal_origin_host
      cert_hosts          = distinct([v.rehearsal_stream_host, v.rehearsal_origin_host, v.live_stream_host, v.live_origin_host])
      pool_count          = v.pool_count
      portal_internal_url = local.portal_internal_url
      live_origin_base    = var.live_origin_base
      ecr_registry        = "${var.account_id}.dkr.ecr.${module.regions.all[k].region}.amazonaws.com"
      images = {
        media-agent  = "${var.account_id}.dkr.ecr.${module.regions.all[k].region}.amazonaws.com/gkoi/media-agent${startswith(local.image_ref["media-agent"], "sha256:") ? "@" : ":"}${local.image_ref["media-agent"]}"
        mediamtx     = "${var.account_id}.dkr.ecr.${module.regions.all[k].region}.amazonaws.com/gkoi/mediamtx${startswith(local.image_ref["mediamtx"], "sha256:") ? "@" : ":"}${local.image_ref["mediamtx"]}"
        media-origin = var.media_origin_image
      }
      engine_source = local.engine_source
      bundle = {
        bucket = var.bundle_bucket
        region = "us-west-2"
        prefix = local.bundle_prefix
        files  = local.bundle_sha
        # a reference, so the config (and through it the ASG) waits for the uploads — no module-level depends_on,
        # which would defer the module's data sources and re-version the launch template on every apply
        uploaded = length([for o in aws_s3_object.bundle : o.key])
      }
      secrets_region = "us-west-2"
      secrets = merge(
        { for n, s in var.engine_secrets : n => data.aws_secretsmanager_secret.engine[n].arn },
        { MEDIA_ORIGIN_VERIFY_SECRET = data.aws_secretsmanager_secret.origin_verify[k].arn },
      )
      origin_verify_json_key      = var.origin_verify_secret_json_key
      agent_env                   = local.agent_env
      origin_max_conns_per_viewer = var.origin_max_conns_per_viewer
      acme                        = { email = var.acme_email, staging = var.acme_staging }
      cw                          = { namespace = "GKOI/Media", log_prefix = "/gkoi/prod2/media/${k}" }
      drain_max_minutes           = var.drain_max_minutes
      udp_buffer_bytes            = var.udp_buffer_bytes
    }
  }

  user_data = {
    for k, v in local.enabled : k => templatefile("${path.module}/box/user-data.sh.tftpl", {
      region       = module.regions.all[k].region
      config_param = "/gkoi/prod2/media/${k}/config"
    })
  }

  rehearsal_records = { for k, v in local.enabled : k => [v.rehearsal_stream_host, v.rehearsal_origin_host] }
  live_records      = { for k, v in local.enabled : k => v.manage_live_records ? [v.live_stream_host, v.live_origin_host] : [] }

  secret_arns = {
    for k, v in local.enabled : k => concat(
      [for n, s in var.engine_secrets : data.aws_secretsmanager_secret.engine[n].arn],
      [data.aws_secretsmanager_secret.origin_verify[k].arn],
    )
  }

  bundle_object_arns = [
    "arn:aws:s3:::${var.bundle_bucket}/${var.bundle_prefix}/*",
    "arn:aws:s3:::${var.bundle_bucket}/mikaido/*/source.zip",
  ]
  recordings_buckets = distinct(concat([var.recordings_bucket], var.extra_vod_buckets))
  ecr_repositories   = ["gkoi/media-agent", "gkoi/mediamtx", "gkoi/media-origin"]
}

# The plan stops here, naming what is missing, before anything is created (a failed precondition fails the plan).
resource "terraform_data" "preflight" {
  input = local.bundle_hash
  lifecycle {
    precondition {
      condition     = length(local.missing_images) == 0
      error_message = "No image digest for: ${join(", ", local.missing_images)} (releases/mikaido.json or var.images)."
    }
    precondition {
      condition     = can(regex("^[0-9a-f]{64}$", local.engine_source.sha256)) && local.engine_source.tag != ""
      error_message = "releases/mikaido.json has no tag / source_sha256: the boxes fetch the engine's config files from that release's source.zip."
    }
    precondition {
      condition     = local.portal_internal_url != ""
      error_message = "No PORTAL_INTERNAL_URL: keep create_engine_internal_alb = true or set engine_internal_url_override."
    }
    precondition {
      condition     = length(local.enabled) == length({ for k, v in var.media_regions : k => v if v.enabled })
      error_message = "A media region is enabled here but paused in modules/regions (no VPC): ${join(", ", [for k, v in var.media_regions : k if v.enabled && !contains(keys(module.regions.enabled), k)])}."
    }
  }
}

# --- the secrets (EXISTING, us-west-2 — read by ARN; values never enter this state) -----------------------------

data "aws_secretsmanager_secret" "engine" {
  for_each = var.engine_secrets
  name     = each.value
}

data "aws_secretsmanager_secret" "origin_verify" {
  for_each = local.enabled
  name     = each.value.origin_verify_secret
}

# --- the box bundle (box/*: the bootstrap, roll, hooks) in the release bucket ------------------------------------

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
  source = "../../../modules/media-box"
  count  = contains(keys(local.enabled), "usw2") ? 1 : 0

  key                         = "usw2"
  region                      = module.regions.all.usw2.region
  account_id                  = var.account_id
  is_home                     = local.home_key == "usw2"
  vpc_id                      = local.net.regions.usw2.vpc_id
  public_subnet_ids           = local.net.regions.usw2.public_subnet_ids
  home_cidr                   = local.net.home_cidr
  ecs_tasks_security_group_id = local.net.ecs_tasks_security_group_id
  instance_type               = coalesce(local.enabled.usw2.instance_type, var.default_instance_type)
  root_volume_gib             = local.enabled.usw2.root_volume_gib
  ami_ssm_parameter           = var.ami_ssm_parameter
  min_size                    = local.enabled.usw2.min_size
  max_size                    = local.enabled.usw2.max_size
  desired_capacity            = local.enabled.usw2.desired_capacity
  pool_count                  = local.enabled.usw2.pool_count
  origin_ingress_cidrs        = local.enabled.usw2.origin_ingress_cidrs
  origin_open_to_world        = local.enabled.usw2.origin_open_to_world
  rehearsal_records           = local.rehearsal_records.usw2
  live_records                = local.live_records.usw2
  zone_id                     = var.zone_id
  acme_names                  = local.config.usw2.cert_hosts
  secret_arns                 = local.secret_arns.usw2
  recordings_buckets          = local.recordings_buckets
  bundle_object_arns          = local.bundle_object_arns
  ecr_repositories            = local.ecr_repositories
  alarm_topic_arn             = try(local.obs.alerts_topic_arns.usw2, null)
  lifecycle_heartbeat_seconds = var.lifecycle_heartbeat_seconds
  config                      = local.config.usw2
  user_data                   = local.user_data.usw2
}

module "box_euc1" {
  source    = "../../../modules/media-box"
  count     = contains(keys(local.enabled), "euc1") ? 1 : 0
  providers = { aws = aws.euc1 }

  key                         = "euc1"
  region                      = module.regions.all.euc1.region
  account_id                  = var.account_id
  is_home                     = false
  vpc_id                      = local.net.regions.euc1.vpc_id
  public_subnet_ids           = local.net.regions.euc1.public_subnet_ids
  home_cidr                   = local.net.home_cidr
  instance_type               = coalesce(local.enabled.euc1.instance_type, var.default_instance_type)
  root_volume_gib             = local.enabled.euc1.root_volume_gib
  ami_ssm_parameter           = var.ami_ssm_parameter
  min_size                    = local.enabled.euc1.min_size
  max_size                    = local.enabled.euc1.max_size
  desired_capacity            = local.enabled.euc1.desired_capacity
  pool_count                  = local.enabled.euc1.pool_count
  origin_ingress_cidrs        = local.enabled.euc1.origin_ingress_cidrs
  origin_open_to_world        = local.enabled.euc1.origin_open_to_world
  rehearsal_records           = local.rehearsal_records.euc1
  live_records                = local.live_records.euc1
  zone_id                     = var.zone_id
  acme_names                  = local.config.euc1.cert_hosts
  secret_arns                 = local.secret_arns.euc1
  recordings_buckets          = local.recordings_buckets
  bundle_object_arns          = local.bundle_object_arns
  ecr_repositories            = local.ecr_repositories
  alarm_topic_arn             = try(local.obs.alerts_topic_arns.euc1, null)
  lifecycle_heartbeat_seconds = var.lifecycle_heartbeat_seconds
  config                      = local.config.euc1
  user_data                   = local.user_data.euc1
}

module "box_use1" {
  source    = "../../../modules/media-box"
  count     = contains(keys(local.enabled), "use1") ? 1 : 0
  providers = { aws = aws.use1 }

  key                         = "use1"
  region                      = module.regions.all.use1.region
  account_id                  = var.account_id
  is_home                     = false
  vpc_id                      = local.net.regions.use1.vpc_id
  public_subnet_ids           = local.net.regions.use1.public_subnet_ids
  home_cidr                   = local.net.home_cidr
  instance_type               = coalesce(local.enabled.use1.instance_type, var.default_instance_type)
  root_volume_gib             = local.enabled.use1.root_volume_gib
  ami_ssm_parameter           = var.ami_ssm_parameter
  min_size                    = local.enabled.use1.min_size
  max_size                    = local.enabled.use1.max_size
  desired_capacity            = local.enabled.use1.desired_capacity
  pool_count                  = local.enabled.use1.pool_count
  origin_ingress_cidrs        = local.enabled.use1.origin_ingress_cidrs
  origin_open_to_world        = local.enabled.use1.origin_open_to_world
  rehearsal_records           = local.rehearsal_records.use1
  live_records                = local.live_records.use1
  zone_id                     = var.zone_id
  acme_names                  = local.config.use1.cert_hosts
  secret_arns                 = local.secret_arns.use1
  recordings_buckets          = local.recordings_buckets
  bundle_object_arns          = local.bundle_object_arns
  ecr_repositories            = local.ecr_repositories
  alarm_topic_arn             = try(local.obs.alerts_topic_arns.use1, null)
  lifecycle_heartbeat_seconds = var.lifecycle_heartbeat_seconds
  config                      = local.config.use1
  user_data                   = local.user_data.use1
}

# --- Valkey (data stack) from the home box: a same-VPC SG reference. The spoke boxes come in through the data
# stack's valkey_peer_cidrs (cross-region peering cannot reference a security group) — README "Apply order". ------

resource "aws_vpc_security_group_ingress_rule" "valkey_from_home_box" {
  count                        = length(module.box_usw2)
  security_group_id            = local.data.valkey_security_group_id
  description                  = "Valkey from the usw2 media box (the relay queues + the pool registry)"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = module.box_usw2[0].security_group_id
}
