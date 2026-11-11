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
# The regions — ONE ASG (min/max 1) per enabled entry. Keys are the CMS / matchd game region codes.
# =================================================================================================================

variable "game_regions" {
  description = <<-EOT
    Per game region (usw2 / euc1 / use1 / apne1 — the codes of the CMS's labs.game_regions and matchd's `region`):
      enabled              create the region's box (ASG, launch template, EIP, SG, role, config, rehearsal records, alarms)
      serve_live_names     false = the box serves (cert, matchd.json, env file) the REHEARSAL names game-<key>-p2 /
                           gw-<key>-p2.gkoi.com; true = the LIVE names game-<key> / gw-<key>.gkoi.com. A running box
                           takes the change with box/roll.sh (drain → new cert → up)
      manage_live_records  true = this stack points the live names at the box's EIP (allow_overwrite: it TAKES OVER the
                           old instance's records — the switch). Needs serve_live_names. prevent_destroy: setting it back
                           to false stops the plan — point the records back by hand + `terraform state rm` (README)
      instance_type        default var.default_instance_type (the live boxes' t3a.xlarge)
      cpu_credits          T types only: standard (the live boxes') | unlimited
      ticket_key_secret    OPTIONAL Secrets Manager name (us-west-2) of this box's gateway-ticket key (base64 of the
                           PKCS#8 v2 DER). null (default) = the box generates its own at first boot (matchd signs and
                           the gateway verifies with the same file on the same box — nothing else holds it)
      root_volume_gib, min_size / max_size / desired_capacity — see the defaults
      rehearsal_matchd_host / rehearsal_gateway_host / live_matchd_host / live_gateway_host — null = the names above
  EOT
  type = map(object({
    enabled                = bool
    serve_live_names       = optional(bool, false)
    manage_live_records    = optional(bool, false)
    instance_type          = optional(string)
    cpu_credits            = optional(string, "standard")
    ticket_key_secret      = optional(string)
    root_volume_gib        = optional(number, 40)
    min_size               = optional(number, 1)
    max_size               = optional(number, 1)
    desired_capacity       = optional(number, 1)
    rehearsal_matchd_host  = optional(string)
    rehearsal_gateway_host = optional(string)
    live_matchd_host       = optional(string)
    live_gateway_host      = optional(string)
  }))
  default = {
    usw2  = { enabled = true }
    euc1  = { enabled = true }
    use1  = { enabled = true }
    apne1 = { enabled = false } # Tokyo: the vCPU quota is pending (operator 2026-11-10); README "Tokyo"
  }
  validation {
    condition     = alltrue([for k, v in var.game_regions : contains(["usw2", "euc1", "use1", "apne1"], k)])
    error_message = "game_regions keys are usw2, euc1, use1, apne1 (the CMS's GAME_REGION_CODES minus dev)."
  }
  validation {
    condition     = alltrue([for v in values(var.game_regions) : v.min_size <= v.desired_capacity && v.desired_capacity <= v.max_size && v.max_size <= 1])
    error_message = "min <= desired <= max <= 1: ONE Elastic IP per region, and no matchd launcher across boxes yet (plan C15)."
  }
  validation {
    condition     = alltrue([for v in values(var.game_regions) : contains(["standard", "unlimited"], v.cpu_credits)])
    error_message = "cpu_credits is standard or unlimited."
  }
  validation {
    condition     = alltrue([for v in values(var.game_regions) : !v.manage_live_records || v.serve_live_names])
    error_message = "manage_live_records needs serve_live_names: the live names must not point at a box that serves another certificate."
  }
  validation {
    condition = alltrue([for v in values(var.game_regions) : alltrue([
      for h in compact([v.rehearsal_matchd_host, v.rehearsal_gateway_host, v.live_matchd_host, v.live_gateway_host]) :
      can(regex("^[a-z0-9-]+\\.gkoi\\.com$", h))
    ])])
    error_message = "Every host must be a single label under gkoi.com (the zone; certbot DNS-01 writes _acme-challenge.<host>)."
  }
}

variable "default_instance_type" {
  description = "The live boxes' type (2026-11-11: t3a.xlarge, credits standard). Plan R2: the War Room's m6a.xlarge / unlimited asks were deferred by the owner."
  type        = string
  default     = "t3a.xlarge"
}

variable "ami_ssm_parameter" {
  description = "Canonical's Ubuntu 24.04 LTS amd64 gp3 (the live boxes run ubuntu-noble-24.04-amd64-server-20261023)."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "matchd_port" {
  type    = number
  default = 9443
}

variable "gateway_port" {
  type    = number
  default = 8443
}

variable "ingress_cidrs" {
  description = "Sources for matchd + the gateway (the live SG: every player)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# =================================================================================================================
# The War Room release — envs/prod2/releases/warroom-game.json (tools/gkoi-release warroom-game <tag>)
# =================================================================================================================

variable "warroom_release_file" {
  description = "The release record (empty = envs/prod2/releases/warroom-game.json)."
  type        = string
  default     = ""
}

variable "warroom_release" {
  description = "Override of releases/warroom-game.json ({tag, commit, source_sha256, digest}); null = the file."
  type = object({
    tag           = string
    commit        = string
    source_sha256 = string
    digest        = string
  })
  default = null
}

variable "warroom_tool_override" {
  description = <<-EOT
    The ops/warroom-game tool the boxes run. null (default) = the SAME source.zip the release's image was built from
    (s3://<bundle_bucket>/warroom-game/<tag>/source.zip, sha256 from the release): one source of truth, version-locked
    to the image. Set it only for a tool/config-only change between War Room releases: a `git archive` zip of
    GKOIBuilder_AI ops/warroom-game at a commit on main, uploaded under warroom-game/tool/<commit>.zip (README).
  EOT
  type = object({
    s3_key = string
    sha256 = string
    commit = string
  })
  default = null
  validation {
    condition     = var.warroom_tool_override == null || can(regex("^warroom-game/", var.warroom_tool_override.s3_key))
    error_message = "The tool zip lives under warroom-game/ in the bundle bucket (the box role reads only there)."
  }
}

variable "match_server_key_secret" {
  description = "Secrets Manager name (us-west-2) of OUR prod match-server key (gk_…, invites:read + plays:write), created EMPTY here."
  type        = string
  default     = "gkoi/prod2/game/match-server-key"
}

# =================================================================================================================
# The box
# =================================================================================================================

variable "bundle_bucket" {
  description = "EXISTING bucket (us-west-2) holding the release zips (warroom-game/<tag>/source.zip) and this stack's box bundle."
  type        = string
  default     = "gkoi-build-sources-127214190346"
}

variable "bundle_prefix" {
  type    = string
  default = "gkoi-infra/game-box"
}

variable "cw_namespace" {
  type    = string
  default = "GKOI/Game"
}

variable "acme_staging" {
  description = "true = Let's Encrypt STAGING certs (a throwaway rehearsal; browsers refuse them)."
  type        = bool
  default     = false
}

variable "lifecycle_heartbeat_seconds" {
  description = "The ASG terminate hook's heartbeat window; lifecycle-watch.sh renews it while matchd drains."
  type        = number
  default     = 900
}

variable "drain_max_minutes" {
  description = "How long a terminating box lets its live matches finish (ops env WARROOM_DRAIN_TIMEOUT is 7500 s = 125 min)."
  type        = number
  default     = 130
}
