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
      hosts        = ["origin-www", "origin-cdn", "origin-labs"]
      min_capacity = 1
      max_capacity = 1
    }
    engine-api = {
      port         = 3000 # the engine api container port (API_PORT default; 3100 is only the dev host port)
      health_path  = "/api/v1/healthz"
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
