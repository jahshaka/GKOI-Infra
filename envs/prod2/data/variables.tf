variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

# --- RDS -------------------------------------------------------------------------------------------------------

variable "db_instance_class" {
  description = "Operator 2026-11-08: db.t4g.small, single-AZ."
  type        = string
  default     = "db.t4g.small"
}

variable "db_engine_version" {
  description = "Major 16 (minor chosen by RDS; auto minor upgrades on)."
  type        = string
  default     = "16"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB)."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Operator 2026-11-08: no Multi-AZ until launch."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_master_username" {
  type    = string
  default = "gkoi_admin"
}

variable "db_backup_window" {
  description = "UTC. 10:00–10:30 UTC = 02:00–02:30 Pacific."
  type        = string
  default     = "10:00-10:30"
}

variable "db_maintenance_window" {
  type    = string
  default = "tue:11:00-tue:12:00"
}

variable "db_log_min_duration_ms" {
  description = "log_min_duration_statement (ms): statements slower than this are logged."
  type        = number
  default     = 1000
}

# --- Valkey ----------------------------------------------------------------------------------------------------

variable "valkey_node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "valkey_engine_version" {
  type    = string
  default = "8.0"
}

variable "valkey_parameter_family" {
  type    = string
  default = "valkey8"
}

variable "valkey_peer_cidrs" {
  description = <<-EOT
    CIDRs allowed to Valkey besides the ECS tasks SG. null (default) = every peered edge VPC from the network stack's
    edge_cidrs (Frankfurt 10.20/16, Virginia 10.30/16; Tokyo once enabled): the media boxes there need REDIS_URL (the
    relay queues + the pool registry, P5). The usw2 media box gets an SG-referenced rule from the media stack instead.
    [] = none. The token (TLS + auth) still gates every connection.
  EOT
  type        = list(string)
  default     = null
}

# --- EFS -------------------------------------------------------------------------------------------------------

variable "efs_throughput_mode" {
  description = "elastic (pay per GB moved; suits a spiky 18 GB site) | bursting (baseline scales with stored GB)."
  type        = string
  default     = "elastic"
}

variable "efs_backup" {
  description = "AWS Backup's daily EFS backup (~$0.05/GB-month)."
  type        = bool
  default     = true
}

variable "secret_recovery_days" {
  type    = number
  default = 7
}
