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
    The CMS's source addresses as the ALB sees them: the Lightsail site box (52.24.67.48, until P4) and the home NAT
    (32.189.104.202 — after P4 the CMS on ECS, like every ECS task, leaves by it). files.gkoi.com serves its non-public
    paths only to these. compute's variable of the same name feeds the engine edge's EDGE_ALLOW_CIDR(_2) and the api's
    TRUSTED_PROXIES — keep the two equal. 1–2 IPv4 CIDRs (the engine edge takes two).
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
