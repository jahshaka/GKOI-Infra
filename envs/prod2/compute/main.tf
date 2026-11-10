# Stage 3 — compute: the ECS Fargate control plane in us-west-2 (cluster gkoi-prod2), its services behind the edge-alb
# target groups, the one-off migrator task definitions, the per-app Secrets Manager entries (created EMPTY) and the
# /gkoi/ roles. Reads network, edge-alb, data and registry state; the log groups come from observability (apply it
# first). Every service min 1 / max 1 (operator 2026-11-10); a deploy surges to 200 %.

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

data "terraform_remote_state" "registry" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "prod2/registry/terraform.tfstate"
    region = "us-west-2"
  }
}

# The origin-live secret's METADATA only (its ARN); the value never enters this state.
data "aws_secretsmanager_secret" "live_origin" {
  name = var.live_origin_secret_id
}

locals {
  region = "us-west-2"
  net    = data.terraform_remote_state.network.outputs
  edge   = data.terraform_remote_state.edge.outputs
  data   = data.terraform_remote_state.data.outputs
  repos  = data.terraform_remote_state.registry.outputs.repositories

  subnets  = local.net.home_private_subnet_ids
  tasks_sg = [local.net.ecs_tasks_security_group_id]
  vpc_cidr = local.net.home_cidr
  tg       = local.edge.target_groups

  # --- images ------------------------------------------------------------------------------------------------
  # envs/prod2/releases/<repo>.json (gkoi-release): { images: { <name>: { digest, image } } }; var.images wins.
  release_files = fileset("${path.module}/../releases", "*.json")
  release_refs = merge([
    for f in local.release_files : {
      for name, img in jsondecode(file("${path.module}/../releases/${f}")).images : name => img.digest
    }
  ]...)
  image_refs = merge(local.release_refs, var.images)

  # Which images the enabled tasks need.
  needed_images = toset(compact(concat(
    ["cms-server", "cms-nginx", "engine-api", "engine-worker", "fm-api", "fm-worker"],
    var.engine_edge_sidecar ? ["engine-edge"] : [],
    var.fm_web_enabled ? ["fm-web"] : [],
  )))
  missing_images = sort([for n in local.needed_images : n if !contains(keys(local.image_refs), n)])
  missing_repos  = sort([for n in local.needed_images : n if !contains(keys(local.repos), n)])

  image = {
    for n in local.needed_images : n => (
      !contains(keys(local.image_refs), n) ? "UNRESOLVED/gkoi/${n}" :
      "${lookup(local.repos, n, "${var.account_id}.dkr.ecr.${local.region}.amazonaws.com/gkoi/${n}")}${startswith(local.image_refs[n], "sha256:") ? "@" : ":"}${local.image_refs[n]}"
    )
  }

  # --- secrets -----------------------------------------------------------------------------------------------
  secret_keys = toset(flatten([for app, names in merge(var.secrets, { for a, n in var.extra_secrets : a => concat(lookup(var.secrets, a, []), n) }) : [for n in names : "${app}/${n}"]]))

  secret_arn = { for k, s in aws_secretsmanager_secret.app : k => s.arn }

  live_origin_value_from = (
    var.live_origin_secret_json_key == null
    ? data.aws_secretsmanager_secret.live_origin.arn
    : "${data.aws_secretsmanager_secret.live_origin.arn}:${var.live_origin_secret_json_key}::"
  )

  # Every "<app>/<NAME>" a container references must be a created secret.
  referenced_secret_keys = toset(concat(
    values(var.cms_server_secret_env), values(var.cms_nginx_secret_env),
    values(var.engine_secret_env), values(var.fm_secret_env),
  ))
  unknown_secret_refs = sort([for k in local.referenced_secret_keys : k if !contains(local.secret_keys, k)])

  # --- plain environment (computed base, then the variable maps on top) -------------------------------------
  cms_server_env = merge(
    {
      DB_HOST = local.data.db_endpoint
      DB_PORT = tostring(local.data.db_port)
    },
    local.default_cms_server_env,
    var.cms_server_env,
  )

  cms_nginx_env = merge(
    { CMS_REALIP_FROM = local.vpc_cidr },
    local.default_cms_nginx_env,
    var.cms_nginx_env,
  )

  engine_env = merge(
    {
      POSTGRES_HOST       = local.data.db_endpoint
      POSTGRES_PORT       = tostring(local.data.db_port)
      POSTGRES_USER       = lookup(merge(local.default_engine_env, var.engine_env), "POSTGRES_APP_USER", "mikaido_app")
      S3_BUCKET           = var.engine_vod_bucket
      CDN_DISTRIBUTION_ID = length(var.engine_cloudfront_distribution_ids) > 0 ? var.engine_cloudfront_distribution_ids[0] : ""
      # With the edge sidecar the api's only proxy is 127.0.0.1 (the edge rebuilds X-Forwarded-For); without it the
      # ALB nodes (in this VPC) write X-Forwarded-For.
      TRUSTED_PROXIES = var.engine_edge_sidecar ? "127.0.0.1" : local.vpc_cidr
    },
    local.default_engine_env,
    var.engine_env,
  )

  engine_edge_env = merge(
    { EDGE_REALIP_FROM = local.vpc_cidr },
    local.default_engine_edge_env,
    var.engine_edge_env,
  )

  fm_env = merge(
    {
      POSTGRES_HOST    = local.data.db_endpoint
      POSTGRES_PORT    = tostring(local.data.db_port)
      POSTGRES_USER    = lookup(merge(local.default_fm_env, var.fm_env), "POSTGRES_APP_USER", "filemanager_app")
      S3_ASSETS_BUCKET = var.fm_assets_bucket
      S3_CREATE_BUCKET = "0" # the bucket exists; its CORS is configured outside the app (S3_MANAGE_CORS=0)
      S3_MANAGE_CORS   = "0"
      TRUSTED_PROXIES  = local.vpc_cidr # the ALB nodes
    },
    local.default_fm_env,
    var.fm_env,
  )

  # The plain env maps a running container carries (for the __SET_ME__ check).
  env_in_use = merge(
    { for k, v in local.cms_server_env : "cms-server.${k}" => v },
    { for k, v in local.cms_nginx_env : "cms-nginx.${k}" => v },
    { for k, v in local.engine_env : "engine.${k}" => v },
    var.engine_edge_sidecar ? { for k, v in local.engine_edge_env : "engine-edge.${k}" => v } : {},
    { for k, v in local.fm_env : "fm.${k}" => v },
  )
  unset_env = sort([for k, v in local.env_in_use : k if v == "__SET_ME__"])
}

# =================================================================================================================
# Preflight: the plan stops here, naming what is missing, before any task definition could point at nothing.
# =================================================================================================================

resource "terraform_data" "preflight" {
  input = {
    images = local.image
  }

  lifecycle {
    precondition {
      condition     = length(local.missing_images) == 0
      error_message = "No image tag/digest for: ${join(", ", local.missing_images)}. Release them (envs/prod2/releases/<repo>.json via tools/gkoi-release) or pass var.images = { <name> = \"<tag>|sha256:…\" }."
    }
    precondition {
      condition     = length(local.missing_repos) == 0
      error_message = "No ECR repository in the registry stack for: ${join(", ", local.missing_repos)}. Add it to registry's build_projects (engine-edge → mikaido) and apply registry first."
    }
    precondition {
      condition     = length(local.unknown_secret_refs) == 0
      error_message = "Container secrets reference entries not in var.secrets: ${join(", ", local.unknown_secret_refs)}."
    }
    precondition {
      condition     = length(local.unset_env) == 0
      error_message = "These environment values are still __SET_ME__: ${join(", ", local.unset_env)}. Set them in the *_env variables (values from the prod box's env; never commit a secret — secrets go in Secrets Manager)."
    }
  }
}

# =================================================================================================================
# Cluster
# =================================================================================================================

resource "aws_ecs_cluster" "this" {
  name = "gkoi-prod2"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "DEFAULT" # ECS Exec sessions: the session is logged through the task's awslogs config
    }
  }

  tags = { Name = "gkoi-prod2" }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

# =================================================================================================================
# Secrets (EMPTY: no aws_secretsmanager_secret_version — the orchestrator fills each value; none is in this state)
# =================================================================================================================

resource "aws_secretsmanager_secret" "app" {
  for_each                = local.secret_keys
  name                    = "gkoi/prod2/${each.value}"
  description             = "GKOI prod2 ${each.value} (an ECS secret). The value is put by the orchestrator, never by Terraform."
  recovery_window_in_days = var.secret_recovery_days
}

# =================================================================================================================
# Log groups the observability stack does not create (its /gkoi/prod2/ecs/<name> list predates the edge sidecar).
# =================================================================================================================

resource "aws_cloudwatch_log_group" "engine_edge" {
  name              = "/gkoi/prod2/ecs/engine-edge"
  retention_in_days = 30
}
