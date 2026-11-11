variable "key" {
  description = "The game region code (usw2 / euc1 / use1 / apne1): matchd's `region`, the CMS's labs.game_regions code."
  type        = string
}

variable "region" {
  description = "The AWS region of this box (the provider's)."
  type        = string
}

variable "account_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "instance_type" {
  description = "The live boxes' t3a.xlarge by default (4 vCPU / 16 GiB, x86 — the Unreal server is amd64)."
  type        = string
}

variable "cpu_credits" {
  description = "T-family credit mode: standard (the live boxes') or unlimited. Ignored for a non-T instance type."
  type        = string
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

variable "matchd_port" {
  description = "matchd's public TLS port (TCP)."
  type        = number
}

variable "gateway_port" {
  description = "The wasm-gateway's public port: TCP (WSS) + UDP (WebTransport)."
  type        = number
}

variable "ingress_cidrs" {
  description = "Who may reach matchd + the gateway (the live SG: 0.0.0.0/0 — every player's browser)."
  type        = list(string)
}

variable "rehearsal_records" {
  description = "NEW names → this box's EIP (created and owned here): game-<key>-p2 + gw-<key>-p2."
  type        = list(string)
}

variable "live_records" {
  description = "The region's live names taken over at the switch (allow_overwrite, prevent_destroy). Empty until then."
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
  description = "The Secrets Manager ARNs (us-west-2) the box reads (the match-server key, an optional ticket key)."
  type        = list(string)
}

variable "bundle_object_arns" {
  description = "S3 object ARNs (patterns) the box downloads: its game-box bundle + the War Room tool's source.zip."
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

variable "cw_namespace" {
  type = string
}

variable "metrics_log_group" {
  description = "The log group the CloudWatch agent's Prometheus scrape writes its EMF records to (created here)."
  type        = string
}

variable "config" {
  description = "The box configuration (non-secret) written to the SSM parameter the bootstrap reads; the module adds the EIP + ASG facts."
  type        = any
}

variable "user_data" {
  description = "The rendered user-data (no secrets: only where the config parameter is)."
  type        = string
}
