variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

variable "zone_id" {
  description = "The EXISTING Route 53 public zone gkoi.com (not managed here)."
  type        = string
  default     = "Z07245612XI342WI698UZ"
}

# =================================================================================================================
# The regions — ONE ASG (min/max 1 today) per enabled entry. Keys are the engine's live-origin slugs.
# =================================================================================================================

variable "media_regions" {
  description = <<-EOT
    Per media region (usw2 / euc1 / use1; the key is the live-origin slug = regionSlug(region)):
      enabled               create the region's box (ASG, EIP, SGs, role, config, rehearsal records, alarms)
      label                 the region's name in the app (the engine's MEDIA_BOX_INSTANCES `label`)
      rehearsal_stream_host NEW name for RTMPS ingest while the box is proven privately (A record → the EIP, created)
      rehearsal_origin_host NEW name for the media origin while proven privately (A record → the EIP, created)
      live_stream_host      the public ingest name the window moves here (stream.gkoi.com …): a record ONLY with
                            manage_live_records; its cert is issued up front (DNS-01 needs no A record)
      live_origin_host      the CloudFront origin name for /r/<slug>/* (origin-live-<slug>.gkoi.com)
      serve_live_names      false = the box registers + serves the rehearsal names; true = the live names (the window)
      manage_live_records   true = this stack points live_stream_host + live_origin_host at the EIP (allow_overwrite:
                            it TAKES OVER an existing record — the window step). prevent_destroy: setting it back to
                            false stops the plan — roll the records back by hand + `terraform state rm` (README)
      origin_verify_secret  the Secrets Manager name of the X-Origin-Verify CloudFront sends to this region's origin
      origin_ingress_cidrs  extra CIDRs to 443 besides CloudFront's origin-facing list (a rehearsal tester)
      origin_open_to_world  443 from anywhere (the Lightsail box's rule); default false = CloudFront only
      instance_type, pool_count (1–5), root_volume_gib, min_size / max_size / desired_capacity — see the defaults
  EOT
  type = map(object({
    enabled               = bool
    label                 = string
    rehearsal_stream_host = string
    rehearsal_origin_host = string
    live_stream_host      = string
    live_origin_host      = string
    serve_live_names      = optional(bool, false)
    manage_live_records   = optional(bool, false)
    origin_verify_secret  = string
    origin_ingress_cidrs  = optional(list(string), [])
    origin_open_to_world  = optional(bool, false)
    instance_type         = optional(string)
    pool_count            = optional(number, 2)
    root_volume_gib       = optional(number, 100)
    min_size              = optional(number, 1)
    max_size              = optional(number, 1)
    desired_capacity      = optional(number, 1)
  }))
  default = {
    usw2 = {
      enabled               = true
      label                 = "Oregon"
      rehearsal_stream_host = "stream-usw2-p2.gkoi.com"
      rehearsal_origin_host = "origin-live-usw2-p2.gkoi.com"
      live_stream_host      = "stream.gkoi.com"
      live_origin_host      = "origin-live-usw2.gkoi.com"
      origin_verify_secret  = "gkoi/media/usw2/origin-verify"
    }
    euc1 = {
      enabled               = true
      label                 = "Frankfurt"
      rehearsal_stream_host = "stream-euc1-p2.gkoi.com"
      rehearsal_origin_host = "origin-live-euc1-p2.gkoi.com"
      live_stream_host      = "stream-euc1.gkoi.com"
      live_origin_host      = "origin-live-euc1.gkoi.com"
      origin_verify_secret  = "gkoi/media/euc1/origin-verify"
    }
    use1 = {
      enabled               = true
      label                 = "Virginia"
      rehearsal_stream_host = "stream-use1-p2.gkoi.com"
      rehearsal_origin_host = "origin-live-use1-p2.gkoi.com"
      live_stream_host      = "stream-use1.gkoi.com"
      live_origin_host      = "origin-live-use1.gkoi.com"
      origin_verify_secret  = "gkoi/media/use1/origin-verify"
    }
  }
  validation {
    condition     = alltrue([for k, v in var.media_regions : contains(["usw2", "euc1", "use1"], k)])
    error_message = "media_regions keys are usw2, euc1, use1 (apne1 needs its provider + module block first)."
  }
  validation {
    condition     = alltrue([for v in values(var.media_regions) : v.pool_count >= 1 && v.pool_count <= 5])
    error_message = "pool_count must be 1-5 (pool i publishes (i+1)1935 / (i+1)1936 / (i+1)8888 / (i+1)8889 / (i+1)9997)."
  }
  validation {
    condition = alltrue([for v in values(var.media_regions) : alltrue([
      for h in [v.rehearsal_stream_host, v.rehearsal_origin_host, v.live_stream_host, v.live_origin_host] :
      can(regex("^[a-z0-9-]+\\.gkoi\\.com$", h))
    ])])
    error_message = "Every host must be a single label under gkoi.com (the zone; certbot DNS-01 writes _acme-challenge.<host>)."
  }
  validation {
    condition     = alltrue([for v in values(var.media_regions) : v.min_size <= v.desired_capacity && v.desired_capacity <= v.max_size && v.max_size <= 1])
    error_message = "min <= desired <= max <= 1: ONE Elastic IP per region (README 'More than one box per region')."
  }
}

variable "default_instance_type" {
  description = "Plan §1: m7i/m7a.xlarge (4 vCPU / 16 GiB, x86 — ffmpeg + MediaMTX images are amd64). m7i is the cheaper of the two."
  type        = string
  default     = "m7i.xlarge"
}

variable "ami_ssm_parameter" {
  description = "Canonical's Ubuntu 24.04 LTS amd64 (the game boxes' and the Lightsail media boxes' OS)."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# =================================================================================================================
# Images — envs/prod2/releases/mikaido.json pins media-agent + mediamtx (the mk-relay pool image) by digest.
# =================================================================================================================

variable "images" {
  description = "Overrides on top of releases/mikaido.json for media-agent / mediamtx: an ECR tag or sha256:<64 hex>."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for v in values(var.images) : can(regex("^(sha256:[0-9a-f]{64}|[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$", v))])
    error_message = "Each images value must be an ECR tag or sha256:<64 hex>."
  }
}

variable "media_origin_ecr_repo" {
  description = <<-EOT
    The media origin is stock nginx with the engine's rendered config (no image of its own — buildspecs/mikaido.yml).
    It runs from OUR ECR mirror (registry extra_repositories, replicated to every media region), resolved per region by
    tag → digest at plan time: the boxes never depend on Docker Hub. The mirror is the live box's exact image
    (nginx:1.27-alpine, amd64, Docker Hub index digest sha256:65645c7b…) — README "The nginx mirror" has the push.
  EOT
  type        = string
  default     = "gkoi/ci-nginx"
}

variable "media_origin_image_tag" {
  type    = string
  default = "1.27-alpine"
}

variable "media_origin_image_override" {
  description = "A full image reference used instead of the mirror (e.g. the Docker Hub nginx:1.27-alpine@sha256:65645c7b… in an emergency). Empty = the mirror."
  type        = string
  default     = ""
}

# =================================================================================================================
# The engine side
# =================================================================================================================

variable "engine_home_region" {
  type    = string
  default = "us-west-2"
}

variable "engine_internal_url_override" {
  description = "PORTAL_INTERNAL_URL for every box instead of edge-alb's internal ALB (empty = its engine_internal.url)."
  type        = string
  default     = ""
}

variable "engine_secrets" {
  description = "Env name → the EXISTING secret (us-west-2, made by compute) the box reads. Values are the engine's own."
  type        = map(string)
  default = {
    REDIS_URL           = "gkoi/prod2/engine/REDIS_URL" # the Valkey URL + /0: the engine's db (the registry + the relay queues)
    RELAY_SHARED_SECRET = "gkoi/prod2/engine/RELAY_SHARED_SECRET"
    MK_POOL_API_PASS    = "gkoi/prod2/engine/MK_POOL_API_PASS"
    MK_POOL_READ_SECRET = "gkoi/prod2/engine/MK_POOL_READ_SECRET"
    PREVIEW_TOKEN_KEY   = "gkoi/prod2/engine/PREVIEW_TOKEN_KEY"
  }
}

variable "origin_verify_secret_json_key" {
  description = "The origin-verify secrets are read as plain strings; set a key when they hold JSON."
  type        = string
  default     = ""
}

variable "live_origin_base" {
  description = "The CDN in front of every regional origin (each pool's liveOriginBase)."
  type        = string
  default     = "https://live.gkoi.com"
}

variable "recordings_bucket" {
  description = "S3_BUCKET of every box (the live boxes' value: ONE bucket in us-west-2 for every region until C6's per-region buckets exist)."
  type        = string
  default     = "gkoi-beta-vods"
}

variable "rehearsal" {
  description = <<-EOT
    The private go-live rehearsal (envs/prod2/rehearsal/README.md). true = every box's agent records into the data
    stack's SCRATCH bucket (output rehearsal_vods_bucket) instead of recordings_bucket, VOD_BUCKETS is dropped, the box
    roles reach ONLY the scratch bucket (the live gkoi-beta-vods is not writable), and the home NAT's addresses
    (network output home_nat_public_ips) are added to every origin's 443 (the driver runs in ECS and leaves by the NAT).
    The plan refuses it while any region serves or manages a live name. A running box picks the change up with
    roll.sh (the role's rights change at once; the agent's env at the roll). Flip it together with compute's `rehearsal`.
  EOT
  type        = bool
  default     = true
}

variable "recordings_bucket_region" {
  type    = string
  default = "us-west-2"
}

variable "extra_vod_buckets" {
  description = "VOD_BUCKETS beyond S3_BUCKET (the role gets the same access). Empty on prod today."
  type        = list(string)
  default     = []
}

variable "agent_env" {
  description = "Plain env for the media agent, merged over the defaults in main.tf (never a secret)."
  type        = map(string)
  default     = {}
}

# =================================================================================================================
# The box
# =================================================================================================================

variable "bundle_bucket" {
  description = "EXISTING bucket (us-west-2) holding the engine release zips (<repo>/<tag>/source.zip) and this stack's box bundle."
  type        = string
  default     = "gkoi-build-sources-127214190346"
}

variable "bundle_prefix" {
  type    = string
  default = "gkoi-infra/media-box"
}

variable "acme_email" {
  description = "Let's Encrypt account email (empty = registered without one, as LE no longer mails expiry notices)."
  type        = string
  default     = ""
}

variable "acme_staging" {
  description = "true = Let's Encrypt STAGING certs (a throwaway rehearsal; apps and CloudFront will refuse them)."
  type        = bool
  default     = false
}

variable "lifecycle_heartbeat_seconds" {
  description = "The ASG terminate hook's heartbeat window; lifecycle-watch.sh renews it while the drain waits."
  type        = number
  default     = 900
}

variable "drain_max_minutes" {
  description = "How long a terminating box waits for its sessions / uploads to finish before it lets go."
  type        = number
  default     = 120
}

variable "udp_buffer_bytes" {
  description = "net.core.rmem_max / wmem_max (WebRTC ICE/UDP; the game boxes' measured tuning)."
  type        = number
  default     = 4194304
}

variable "origin_max_conns_per_viewer" {
  type    = number
  default = 100
}
