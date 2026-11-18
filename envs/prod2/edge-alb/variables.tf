variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

variable "zone_name" {
  description = "The EXISTING Route 53 public zone (read only; this stack adds ACM validation CNAMEs and nothing else)."
  type        = string
  default     = "gkoi.com"
}

variable "live_origin_secret_id" {
  description = "Secrets Manager entry whose value every origin-live request must carry in X-Origin-Verify."
  type        = string
  default     = "gkoi/edge/live-origin"
}

variable "live_origin_secret_json_key" {
  description = "null = the secret string IS the value; else the JSON key holding it."
  type        = string
  default     = null
}

variable "idle_timeout" {
  description = "ALB idle timeout (s). The engine edge's long reads (LL-HLS, SSE) use 300 s."
  type        = number
  default     = 300
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "ssl_policy" {
  type    = string
  default = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# The control-plane services behind this ALB. `hosts` are labels under zone_name. min/max are the ECS service
# bounds the compute stack reads from this stack's outputs (operator 2026-11-10: min 1 / max 1 until raised).
# fm-web has no public host (the FM admin console is reached through the site's admin mount), so its target
# group exists for the compute stack but no listener rule routes to it.
variable "services" {
  type = map(object({
    port         = number
    health_path  = string
    hosts        = list(string)
    min_capacity = number
    max_capacity = number
  }))
  default = {
    cms = {
      port         = 8080 # the CMS container nginx (NGINX_LISTEN 8080), which proxies the server
      health_path  = "/api/v1/healthz"
      hosts        = ["origin-www", "origin-cdn", "origin-labs", "www"] # www: CloudFront www.gkoi.com forwards the viewer's Host (B4-2)
      min_capacity = 1
      max_capacity = 1
    }
    engine-api = {
      port         = 8080 # the engine EDGE sidecar (SPEC-ENGINE-EDGE-SIDECAR-V1) in front of the api (3000); orchestrator 2026-11-10
      health_path  = "/healthz"
      hosts        = ["engine"]
      min_capacity = 1
      max_capacity = 1
    }
    fm-api = {
      port         = 3200 # the FM api container port (API_PORT default)
      health_path  = "/api/v1/healthz"
      hosts        = ["files"]
      min_capacity = 1
      max_capacity = 1
    }
    fm-web = {
      port         = 80 # the fm-web nginx container (compose maps 127.0.0.1:8200 → 80)
      health_path  = "/"
      hosts        = []
      min_capacity = 1
      max_capacity = 1
    }
  }
  validation {
    condition     = alltrue([for s in values(var.services) : s.min_capacity >= 0 && s.max_capacity >= s.min_capacity])
    error_message = "Each service needs 0 <= min_capacity <= max_capacity."
  }
}

variable "live_origin_host" {
  description = "The CloudFront live origin label; requests to it are locked to X-Origin-Verify and /api/v1/watch/*."
  type        = string
  default     = "origin-live"
}

variable "live_origin_path" {
  type    = string
  default = "/api/v1/watch/*"
}

# --- audit 2026-11-11: the cms hosts (B4-2/3/4) and the files allow-list (B3-6) ---------------------------------

variable "cms_source_cidrs" {
  description = <<-EOT
    The CMS's source addresses as the ALB sees them: the home NAT (32.189.104.202 — the CMS on ECS, like every ECS
    task, leaves by it). files.gkoi.com serves its non-public paths only to these. compute's variable of the same name
    feeds the engine edge's EDGE_ALLOW_CIDR(_2) and the api's TRUSTED_PROXIES — keep the two equal. 1–2 IPv4 CIDRs (the
    engine edge takes two). History: until the P4 window (2026-11-11) the list also held the Lightsail site box,
    52.24.67.48 — that server was retired on 2026-11-17 and its address released: never add it back.
  EOT
  type        = list(string)
  default     = ["32.189.104.202/32"]
  validation {
    condition = (
      length(var.cms_source_cidrs) >= 1 && length(var.cms_source_cidrs) <= 2 &&
      alltrue([for c in var.cms_source_cidrs : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/([89]|[12][0-9]|3[0-2])$", c)) && can(cidrhost(c, 0))])
    )
    error_message = "cms_source_cidrs: 1–2 IPv4 CIDRs, prefix /8–/32."
  }
}

variable "cms_cdn_origin_host" {
  description = "The cdn.gkoi.com distribution's origin label (one of services.cms.hosts): only cms_cdn_paths, GET/HEAD."
  type        = string
  default     = "origin-cdn"
}

variable "cms_cdn_paths" {
  description = "What origin-cdn serves (prod's host nginx: ^~ /content/ and ^~ /assets/). At most 2."
  type        = list(string)
  default     = ["/content/*", "/assets/*"]
}

variable "cms_labs_origin_host" {
  description = "The labs.gkoi.com distribution's origin label (one of services.cms.hosts): /content/labs/** GET/HEAD; other GET/HEAD → 302 to the site's /labs."
  type        = string
  default     = "origin-labs"
}

variable "cms_site_host" {
  description = "The site's canonical label (www): where the apex and the labs host's other paths redirect."
  type        = string
  default     = "www"
}

variable "cms_site_origin_host" {
  description = "The www.gkoi.com distribution's origin label (one of services.cms.hosts): the host of the site-origin lock's open door (cms_origin_open_paths)."
  type        = string
  default     = "origin-www"
}

# --- the site-origin lock (audit 2026-11-17; README "The site-origin lock") --------------------------------------

variable "site_origin_secret_name" {
  description = "The Secrets Manager entry (created EMPTY by this stack) whose value CloudFront www / cdn / labs send to their origins in X-Origin-Verify."
  type        = string
  default     = "gkoi/prod2/edge/site-origin"
}

variable "site_origin_lock" {
  description = <<-EOT
    false = the cms hosts (origin-www / www / origin-cdn / origin-labs) answer anyone, as before 2026-11-17. true = they
    forward ONLY requests carrying the site-origin secret in X-Origin-Verify; everything else on them is a 403 (except
    cms_origin_open_paths). Turn it on ONLY after the three CloudFront distributions send the header and are Deployed
    (tools/gkoi-origin-header check must PASS) — the README has the order and the rollback (set it back to false and
    apply). The plan itself stops when the secret is empty or malformed, or a distribution is not Deployed.
  EOT
  type        = bool
  default     = false
}

variable "site_cloudfront_distributions" {
  description = "The hand-managed CloudFront distributions whose origins are the locked cms hosts (name → id). With the lock on, a plan stops unless each is Deployed."
  type        = map(string)
  default = {
    www  = "E32GUUVFJFZWS7"
    cdn  = "E16YQ7HYLBQUPQ"
    labs = "E28154TBILFIGK"
  }
}

variable "cms_origin_open_paths" {
  description = <<-EOT
    Paths of origin-www.gkoi.com that stay reachable WITHOUT the site-origin secret while the lock is on: exactly what
    the build boxes' publish CLIs call there (aisolver-www scripts/downloads/publish.mjs, scripts/updater/submit.mjs) —
    the upload (multi-GiB bodies sent straight to the origin), the submission routes, the tool's self-check. Never widen
    it to /api/v1/app-updates/* (/check trusts the CDN's viewer-country header). At most 4 (1 host + 4 paths = the
    5-value rule limit). [] = nothing stays open.
  EOT
  type        = list(string)
  default     = ["/api/v1/downloads/*", "/api/v1/app-updates/submissions*", "/api/v1/app-updates/tool/info"]
  validation {
    condition     = length(var.cms_origin_open_paths) <= 4 && alltrue([for p in var.cms_origin_open_paths : startswith(p, "/api/v1/")])
    error_message = "cms_origin_open_paths: at most 4 paths, each under /api/v1/."
  }
}

variable "apex_redirect" {
  description = "true: the certificate also names the apex (zone_name) and a rule 301s it to cms_site_host (prod's apex server block)."
  type        = bool
  default     = true
}

variable "fm_public_paths" {
  description = "files.gkoi.com paths open to everyone (prod's public file-manager listener). Every other path: cms_source_cidrs only, else 404."
  type        = list(string)
  default     = ["/api/v1/app/*", "/thumbs/*", "/api/v1/healthz", "/api/v1/readyz"]
}

variable "create_engine_internal_alb" {
  description = "The internal ALB the media boxes reach the engine api's /internal/** through (internal-alb.tf; P5)."
  type        = bool
  default     = true
}

# --- the private service calls (SPEC-INFRA-PRIVATE-SERVICE-CALLS-V1; envs/prod2/PRIVATE-SERVICE-CALLS-RUNBOOK.md) ----

variable "create_private_service_listeners" {
  description = <<-EOT
    true = the internal ALB (create_engine_internal_alb) gains two plain-HTTP listeners that only the ECS tasks SG may
    reach: private_engine_port → the engine api's own :3000 (/api/* and /ws/* only — never /internal/*) and
    private_files_port → a new target group gkoi-prod2-fm-api-int (fm-api :3200, /api/* only). Inert alone: nothing
    calls them until compute's private_files_calls / private_engine_calls are turned on. Output private_services
    (null while off). Rollback: false + apply (after compute's two call flags are back to false).
  EOT
  type        = bool
  default     = true
}

variable "private_engine_port" {
  description = "The internal ALB listener port the site reaches the engine api on (create_private_service_listeners)."
  type        = number
  default     = 3100
  validation {
    condition     = var.private_engine_port >= 1024 && var.private_engine_port <= 65535 && var.private_engine_port != 3000
    error_message = "private_engine_port: 1024–65535 and not 3000 (the media boxes' listener)."
  }
}

variable "private_files_port" {
  description = "The internal ALB listener port the site reaches the file manager api on (create_private_service_listeners)."
  type        = number
  default     = 3200
  validation {
    condition     = var.private_files_port >= 1024 && var.private_files_port <= 65535 && var.private_files_port != 3000
    error_message = "private_files_port: 1024–65535 and not 3000 (the media boxes' listener)."
  }
}

variable "engine_internal_idle_timeout" {
  description = <<-EOT
    The internal ALB's idle timeout (s). 60 = today. 300 = the public ALB's value (var.idle_timeout): wanted once the
    site's chat WebSocket goes through this ALB (compute private_engine_calls), because the engine's chat gateway sends
    no pings and an idle socket would be cut at 60 s (SPEC-INFRA-PRIVATE-SERVICE-CALLS-V1 P4 / Q3). The agents' and
    the site's HTTP keep-alive (55 s) stay below either value. In-place change, no replacement.
  EOT
  type        = number
  default     = 300
  validation {
    condition     = var.engine_internal_idle_timeout >= 60 && var.engine_internal_idle_timeout <= 4000
    error_message = "engine_internal_idle_timeout: 60–4000 s (below 60 would cut the 55 s keep-alive sockets)."
  }
}

variable "fm_publisher_cidrs" {
  description = <<-EOT
    Build boxes that publish to the file manager with a scoped BUILD KEY (fm-publish; GKOI Live's cook boxes). They may
    reach files.gkoi.com /api/v1/admin/* (every route there still needs its own credential: a build key, the gateway
    identity or an admin session). Empty = no rule. At most 3 IPv4 CIDRs, /24 or narrower.
  EOT
  type        = list(string)
  default     = ["88.20.102.164/32"]
  validation {
    condition = (
      length(var.fm_publisher_cidrs) <= 3 &&
      alltrue([for c in var.fm_publisher_cidrs : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/(2[4-9]|3[0-2])$", c)) && can(cidrhost(c, 0))])
    )
    error_message = "fm_publisher_cidrs: at most 3 IPv4 CIDRs, prefix /24 to /32."
  }
}
