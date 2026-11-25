variable "key" {
  description = "The region key AND live-origin slug (usw2 / euc1 / use1): the engine's regionSlug(region)."
  type        = string
}

variable "region" {
  description = "The AWS region of this box (the provider's)."
  type        = string
}

variable "account_id" {
  type = string
}

variable "is_home" {
  description = "true = this box sits in the home VPC (usw2): the ECS tasks reach it by security group, not by CIDR."
  type        = bool
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "home_cidr" {
  description = "The home VPC CIDR: the engine api / worker tasks (proxies, readiness reads) reach the pools' private ports from it."
  type        = string
}

variable "ecs_tasks_security_group_id" {
  description = "Home box only: the ECS tasks SG (a same-VPC rule references it instead of the whole home CIDR)."
  type        = string
  default     = null
}

variable "instance_type" {
  type = string
}

variable "root_volume_gib" {
  type = number
}

variable "ami_ssm_parameter" {
  description = "The SSM public parameter naming the AMI (Canonical's Ubuntu 24.04 amd64 gp3)."
  type        = string
}

variable "min_size" {
  type = number
}

variable "max_size" {
  type = number
}

variable "desired_capacity" {
  type = number
}

variable "pool_count" {
  type = number
}

variable "origin_ingress_cidrs" {
  description = "Extra IPv4 CIDRs allowed to the media origin's 443 besides CloudFront's origin-facing prefix list (a rehearsal tester). Empty = CloudFront only."
  type        = list(string)
}

variable "origin_open_to_world" {
  description = "true = 443 from 0.0.0.0/0 (the retired Lightsail box's rule; the X-Origin-Verify lock is then the only gate)."
  type        = bool
}

variable "rehearsal_records" {
  description = "NEW names → this box's EIP (created and owned here)."
  type        = list(string)
}

variable "live_records" {
  description = "EXISTING live names taken over in the window (allow_overwrite, prevent_destroy). Empty until then."
  type        = list(string)
  default     = []
}

variable "zone_id" {
  type = string
}

variable "acme_names" {
  description = "Every hostname this box may issue a Let's Encrypt cert for by DNS-01 (rehearsal + live names): the IAM condition."
  type        = list(string)
}

variable "secret_arns" {
  description = "The Secrets Manager ARNs (us-west-2) this box's bootstrap reads."
  type        = list(string)
}

variable "recordings_buckets" {
  description = "The recordings buckets the media agent writes / reads (S3_BUCKET + VOD_BUCKETS)."
  type        = list(string)
}

variable "bundle_object_arns" {
  description = "S3 object ARNs (patterns) the box downloads at boot / roll: its tool bundle + the engine release's source.zip."
  type        = list(string)
}

variable "ecr_repositories" {
  description = "gkoi/* repository names the box pulls in its own region (replicated from us-west-2)."
  type        = list(string)
}

variable "alarm_topic_arn" {
  description = "The region's gkoi-ops-alerts topic (null = no alarm actions)."
  type        = string
  default     = null
}

variable "lifecycle_heartbeat_seconds" {
  type = number
}

variable "config" {
  description = "The box configuration (non-secret) written to the SSM parameter the bootstrap reads; the module adds the EIP + ASG facts."
  type        = any
}

variable "user_data" {
  description = "The rendered user-data (no secrets: only where the config parameter is)."
  type        = string
}

# --- SPEC-ONE-INGEST-ADDRESS-V1 (1.1.8): every default = today's behaviour (no resource, no rule, no change) ---------

variable "srt_enabled" {
  description = "true = the public SRT ingest ports udp (i+1)8890 (18890 / 28890) open to the world, like the RTMPS ports."
  type        = bool
  default     = false
}

variable "auto_host" {
  description = <<-EOT
    The automatic ingest name (stream.gkoi.com); "" = off. Set: the region's IngestAccepting metric (two metric filters
    on the container log group), its alarm, and the three Route 53 health checks (TCP on pool 0's RTMPS port + the
    alarm, CALCULATED = both). The latency record itself only with auto_latency_record.
  EOT
  type        = string
  default     = ""
}

variable "auto_latency_record" {
  description = <<-EOT
    true = this region's member of the auto_host latency set (A, set identifier = key, latency region = region, TTL 60,
    the calculated health check). Created by the ONE manual Route 53 change batch and IMPORTED here (README "The one
    ingest address + SRT (1.1.8)"); prevent_destroy like the live names.
  EOT
  type        = bool
  default     = false
}

variable "log_prefix" {
  description = "The box's CloudWatch log group prefix (/gkoi/prod2/media/<key>; the observability stack owns the groups)."
  type        = string
  default     = ""
}

variable "cert_renewal_alarm" {
  description = "true = a metric filter on the box's bootstrap log group (certbot's log ships there) + an alarm on any renewal / issue failure."
  type        = bool
  default     = false
}

variable "health_check_regions" {
  description = "The Route 53 checker regions for the TCP check (minimum 3: fewer probes = fewer TLS-less connects in the pool's log)."
  type        = list(string)
  default     = ["us-west-1", "us-east-1", "eu-west-1"]
}
