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
  description = "true = 443 from 0.0.0.0/0 (the Lightsail box's rule; the X-Origin-Verify lock is then the only gate)."
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
