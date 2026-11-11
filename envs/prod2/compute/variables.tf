variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

# =================================================================================================================
# Images — repo name (gkoi/<name>) → an immutable tag or a digest (sha256:…).
# =================================================================================================================

variable "images" {
  description = <<-EOT
    Overrides on top of envs/prod2/releases/*.json (lane C's gkoi-release writes one per repo: images.<name>.digest).
    A value is an ECR tag (gkoi-2026.11.11-1) or a digest (sha256:<64 hex>). Every image an enabled task uses must
    resolve from one of the two, or the plan stops with the list of the missing ones.
  EOT
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for v in values(var.images) : can(regex("^(sha256:[0-9a-f]{64}|[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$", v))])
    error_message = "Each images value must be an ECR tag or sha256:<64 hex>."
  }
}

# =================================================================================================================
# Switches
# =================================================================================================================

variable "engine_edge_sidecar" {
  description = <<-EOT
    true (SPEC-ENGINE-EDGE-SIDECAR-V1): the engine-api task = api + the gkoi/engine-edge nginx; the ALB forwards to
    the edge on engine_edge_port. false: the ALB forwards to the api on 3000 directly (a rehearsal before the edge image
    exists — the origin-live lock then rests on the ALB rules alone).
  EOT
  type        = bool
  default     = true
}

variable "engine_edge_port" {
  type    = number
  default = 8080
}

variable "fm_web_enabled" {
  description = "Run the FM admin console (fm-web). Nothing routes to it today — see README 'fm-web'. Off (orchestrator 2026-11-10)."
  type        = bool
  default     = false
}

variable "fm_web_attach_lb" {
  description = "Register fm-web in its target group. Only once a listener rule forwards to that group (ECS refuses a target group with no load balancer)."
  type        = bool
  default     = false
}

variable "wait_for_steady_state" {
  description = "true = an apply waits for every changed service to reach a steady deployment (fails on a rollback)."
  type        = bool
  default     = false
}

# =================================================================================================================
# Sizes and counts
# =================================================================================================================

variable "sizes" {
  description = "Fargate task size per task family (cpu units / MiB)."
  type = map(object({
    cpu    = number
    memory = number
  }))
  default = {
    cms              = { cpu = 1024, memory = 2048 }
    engine-api       = { cpu = 1024, memory = 2048 }
    engine-worker    = { cpu = 1024, memory = 2048 }
    fm-api           = { cpu = 512, memory = 1024 }
    fm-worker        = { cpu = 512, memory = 2048 } # compose: mem_limit 1536m
    fm-web           = { cpu = 256, memory = 512 }
    cms-migrate      = { cpu = 512, memory = 1024 }
    cms-content-sync = { cpu = 1024, memory = 2048 }
    engine-migrate   = { cpu = 512, memory = 1024 }
    fm-migrate       = { cpu = 256, memory = 512 }
  }
}

variable "engine_worker_ephemeral_gib" {
  description = <<-EOT
    The engine worker's disk (the Download MP4 build's scratch, VOD_BUILD_DIR). Worst case: a 130-minute recording at
    12 Mb/s = 130 × 60 × 12e6 / 8 ≈ 11.7 GB; the build needs ~2.2 × that ≈ 25.7 GB plus the 2 GB reserve ≈ 27.7 GB,
    plus the image layers (~2 GB, they share this disk). 60 GiB = one worst-case build with 2× headroom (or two at
    once, VOD_MP4_CONCURRENCY=2, just fitting). Fargate allows 21–200.
  EOT
  type        = number
  default     = 60
  validation {
    condition     = var.engine_worker_ephemeral_gib >= 50 && var.engine_worker_ephemeral_gib <= 200
    error_message = "engine_worker_ephemeral_gib must be 50–200 (a 130-minute 12 Mb/s Download build needs ~28 GB free)."
  }
}

variable "worker_capacity" {
  description = "min/max of the services WITHOUT a target group. The load-balanced ones read theirs from edge-alb's outputs (raise them there)."
  type = map(object({
    min = number
    max = number
  }))
  default = {
    engine-worker = { min = 1, max = 1 }
    fm-worker     = { min = 1, max = 1 }
  }
}

variable "fm_web_capacity" {
  description = "fm-web's bounds when it is not registered in its target group (fm_web_attach_lb = false)."
  type = object({
    min = number
    max = number
  })
  default = { min = 1, max = 1 }
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

# =================================================================================================================
# Secrets — Secrets Manager entries gkoi/prod2/<app>/<NAME>, created EMPTY (no version). The orchestrator fills each
# before the first task starts (an ECS secret without a value stops the task: ResourceNotFoundException).
# =================================================================================================================

variable "secrets" {
  description = "app → the secret names created under gkoi/prod2/<app>/."
  type        = map(list(string))
  default = {
    cms = [
      "DB_PASSWORD",
      "AUTH_ENCRYPTION_KEY",
      "APP_API_SECRET",
      "LABS_SUB_KEY",
      "COMMERCE_PAYOUT_KEY",
      "RATE_LIMIT_REDIS_URL",
      "SMTP_PASS",
      "CONTENT_SYNC_SSH_KEY",
    ]
    engine = [
      "POSTGRES_APP_PASSWORD",
      "REDIS_URL",
      "SESSION_COOKIE_SECRET",
      "VAULT_MASTER_KEY",
      "GATEWAY_SHARED_SECRET",
      "RELAY_SHARED_SECRET",
      "MK_POOL_READ_SECRET",
      "MK_POOL_API_PASS",
      "PREVIEW_TOKEN_KEY",
      "TWITCH_CLIENT_SECRET",
      "GOOGLE_CLIENT_SECRET",
      "KICK_CLIENT_SECRET",
    ]
    fm = [
      "POSTGRES_APP_PASSWORD",
      "REDIS_URL",
      "SESSION_COOKIE_SECRET",
      "VAULT_MASTER_KEY",
      "GATEWAY_SHARED_SECRET",
      "CDN_PRIVATE_KEY_B64",
    ]
  }
}

variable "extra_secrets" {
  description = "app → MORE names to create (added to var.secrets), e.g. { cms = [\"CMS_LABS_ISOLATION_TOKEN\"] } with cms_nginx_secret_env."
  type        = map(list(string))
  default     = {}
}

variable "secret_recovery_days" {
  type    = number
  default = 7
}

# env var → "<app>/<SECRET NAME>" (one of var.secrets). A value shared by two services is ONE secret: the CMS's
# GATEWAY_SHARED_SECRET IS the engine's; its FILES_SHARED_SECRET IS the file manager's GATEWAY_SHARED_SECRET.
variable "cms_server_secret_env" {
  type = map(string)
  default = {
    DB_PASSWORD           = "cms/DB_PASSWORD"
    AUTH_ENCRYPTION_KEY   = "cms/AUTH_ENCRYPTION_KEY"
    APP_API_SECRET        = "cms/APP_API_SECRET"
    LABS_SUB_KEY          = "cms/LABS_SUB_KEY"
    RATE_LIMIT_REDIS_URL  = "cms/RATE_LIMIT_REDIS_URL"
    GATEWAY_SHARED_SECRET = "engine/GATEWAY_SHARED_SECRET"
    FILES_SHARED_SECRET   = "fm/GATEWAY_SHARED_SECRET"
  }
}

variable "cms_nginx_secret_env" {
  description = "Optional: CMS_LABS_ISOLATION_TOKEN = \"cms/CMS_LABS_ISOLATION_TOKEN\" (and extra_secrets = { cms = [\"CMS_LABS_ISOLATION_TOKEN\"] })."
  type        = map(string)
  default     = {}
}

variable "engine_secret_env" {
  description = "The api, the worker and the migrator share one engine env (as compose's one env file). POSTGRES_PASSWORD is the APP role's password too: the api schema requires it, and the RDS master never reaches a task."
  type        = map(string)
  default = {
    POSTGRES_PASSWORD     = "engine/POSTGRES_APP_PASSWORD"
    POSTGRES_APP_PASSWORD = "engine/POSTGRES_APP_PASSWORD"
    REDIS_URL             = "engine/REDIS_URL"
    SESSION_COOKIE_SECRET = "engine/SESSION_COOKIE_SECRET"
    VAULT_MASTER_KEY      = "engine/VAULT_MASTER_KEY"
    GATEWAY_SHARED_SECRET = "engine/GATEWAY_SHARED_SECRET"
    RELAY_SHARED_SECRET   = "engine/RELAY_SHARED_SECRET"
    MK_POOL_READ_SECRET   = "engine/MK_POOL_READ_SECRET"
    MK_POOL_API_PASS      = "engine/MK_POOL_API_PASS"
    PREVIEW_TOKEN_KEY     = "engine/PREVIEW_TOKEN_KEY"
  }
}

variable "fm_secret_env" {
  description = "fm-api, fm-worker and the migrator share one FM env. POSTGRES_PASSWORD = the app role's (as the engine)."
  type        = map(string)
  default = {
    POSTGRES_PASSWORD     = "fm/POSTGRES_APP_PASSWORD"
    POSTGRES_APP_PASSWORD = "fm/POSTGRES_APP_PASSWORD"
    REDIS_URL             = "fm/REDIS_URL"
    SESSION_COOKIE_SECRET = "fm/SESSION_COOKIE_SECRET"
    VAULT_MASTER_KEY      = "fm/VAULT_MASTER_KEY"
    GATEWAY_SHARED_SECRET = "fm/GATEWAY_SHARED_SECRET"
    CDN_PRIVATE_KEY_B64   = "fm/CDN_PRIVATE_KEY_B64"
  }
}

variable "live_origin_secret_id" {
  description = "The EXISTING origin-live secret (edge-alb reads the same one). Only its ARN is read here, never its value."
  type        = string
  default     = "gkoi/edge/live-origin"
}

variable "live_origin_secret_json_key" {
  description = "null = the secret string IS the value; else the JSON key holding it (as edge-alb)."
  type        = string
  default     = null
}

# =================================================================================================================
# Plain environment. The defaults live in env-defaults.tf (locals); these maps are MERGED on top (a key here wins,
# the other defaults stay). "__SET_ME__" in a default = a value only the operator / the prod box knows: the plan
# refuses to run while any enabled container still carries one. Never put a secret here — secrets go in Secrets Manager.
# =================================================================================================================

variable "cms_server_env" {
  type    = map(string)
  default = {}
}

variable "cms_nginx_env" {
  type    = map(string)
  default = {}
}

variable "engine_env" {
  description = "The api, the worker and the engine migrator share it (compose's one env file)."
  type        = map(string)
  default     = {}
}

variable "engine_edge_env" {
  description = "Overrides for the edge sidecar (PROVISIONAL names — SPEC-ENGINE-EDGE-SIDECAR-V1 E1; align with lane B's image)."
  type        = map(string)
  default     = {}
}

variable "fm_env" {
  description = "fm-api, fm-worker and the FM migrator share it."
  type        = map(string)
  default     = {}
}

# =================================================================================================================
# What the tasks may touch (existing resources, not managed here)
# =================================================================================================================

variable "engine_vod_bucket" {
  description = "The engine's recordings bucket (S3_BUCKET). Existing, us-west-2, SSE-S3."
  type        = string
  default     = "gkoi-beta-vods"
}

variable "engine_extra_vod_buckets" {
  description = "Every other recordings bucket the engine reads (its VOD_BUCKETS allow-list) — the role gets the same access."
  type        = list(string)
  default     = []
}

variable "engine_cloudfront_distribution_ids" {
  description = "Distributions the engine invalidates (CDN_DISTRIBUTION_ID: vod.gkoi.com)."
  type        = list(string)
  default     = ["E2LXDFW5VZ1UHD"]
}

variable "engine_metrics_namespace" {
  description = "The CloudWatch namespace the engine may publish to (METRICS_CLOUDWATCH_NAMESPACE, A7; off until that is set)."
  type        = string
  default     = "GKOI/Engine"
}

variable "fm_assets_bucket" {
  description = "The file manager's assets bucket (S3_ASSETS_BUCKET). Existing, us-west-2, SSE-S3."
  type        = string
  default     = "gkoi-beta-files"
}

variable "content_sync_image" {
  description = "The content-sync task's image (public, no ECR auth needed)."
  type        = string
  default     = "public.ecr.aws/docker/library/alpine:3.20"
}

variable "content_sync_host" {
  description = "The Lightsail site box (the CMS content's source); temporary, until Lightsail is retired."
  type        = string
  default     = "52.24.67.48"
}

variable "content_sync_host_key" {
  description = "The site box's SSH host key line (known_hosts format); public."
  type        = string
  default     = "52.24.67.48 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9XanMB8BekTf1He1rSTstBKMuyU0kVXZtyacMMhvlX"
}

variable "parked_services" {
  description = <<-EOT
    The services held at 0 tasks (min = max = 0). Default: ALL of them (the state since 2026-11-11 — the services share
    the LIVE buckets and call the live hosts, so they run only inside a switch-over window). The private go-live
    rehearsal runs the engine alone: ["cms", "fm-api", "fm-worker", "fm-web"] together with rehearsal = true
    (envs/prod2/rehearsal/README.md). The window: []. Replaces the old all-or-nothing `parked` (true = this default,
    false = []).
  EOT
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for s in var.parked_services : contains(["cms", "engine-api", "engine-worker", "fm-api", "fm-worker", "fm-web"], s)])
    error_message = "parked_services names services: cms, engine-api, engine-worker, fm-api, fm-worker, fm-web."
  }
}

variable "rehearsal" {
  description = <<-EOT
    The private go-live rehearsal (envs/prod2/rehearsal/README.md). true = the engine (api, worker, migrator) records
    into the data stack's SCRATCH bucket (S3_BUCKET = data output rehearsal_vods_bucket; VOD_BUCKETS dropped) and its
    task roles reach ONLY that bucket — gkoi-beta-vods (the live one) is neither configured nor writable; the vod.gkoi.com
    CDN is not used (CDN_DOWNLOAD_BASE and CDN_DISTRIBUTION_ID blank, no invalidation right). The plan refuses it unless
    cms and the file manager stay parked (they share the live buckets). Flip it together with media's `rehearsal`.
    NEVER true in the window: recordings would land in a bucket that expires them after 3 days.
  EOT
  type        = bool
  default     = false
}

variable "cms_source_cidrs" {
  description = <<-EOT
    The CMS's source addresses as engine.gkoi.com / files.gkoi.com see them (audit 2026-11-11 B3-5): the Lightsail site
    box (52.24.67.48, until P4) and the home NAT (32.189.104.202 — after P4 the CMS on ECS leaves by it; so does every
    other ECS task). The engine edge's EDGE_ALLOW_CIDR / _2 and the api's TRUSTED_PROXIES. edge-alb has the same
    variable (the files allow-list) — keep the two equal. 1–2 IPv4 CIDRs (the edge template takes two).
  EOT
  type        = list(string)
  default     = ["52.24.67.48/32", "32.189.104.202/32"]
  validation {
    condition = (
      length(var.cms_source_cidrs) >= 1 && length(var.cms_source_cidrs) <= 2 &&
      alltrue([for c in var.cms_source_cidrs : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/([89]|[12][0-9]|3[0-2])$", c)) && can(cidrhost(c, 0))])
    )
    error_message = "cms_source_cidrs: 1–2 IPv4 CIDRs, prefix /8–/32 (the api refuses a wider TRUSTED_PROXIES entry)."
  }
}

variable "engine_internal_lb" {
  description = "Register engine-api's api:3000 in edge-alb's INTERNAL target group (the media boxes' /internal/** path, P5). Off = the public target group only."
  type        = bool
  default     = true
}
