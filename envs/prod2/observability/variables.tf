variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

variable "alerts_topic_name" {
  description = "The EXISTING per-region SNS topic (usw2 / euc1 / use1). Not managed here."
  type        = string
  default     = "gkoi-ops-alerts"
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "ecs_log_streams" {
  description = "The home-region ECS log groups: /gkoi/prod2/ecs/<name>."
  type        = list(string)
  default = [
    "cms-server",
    "cms-nginx",
    "cms-migrate",
    "engine-api",
    "engine-worker",
    "engine-web",
    "engine-migrate",
    "fm-api",
    "fm-worker",
    "fm-web",
    "fm-migrate",
  ]
}

variable "box_log_streams" {
  description = "Per enabled region: /gkoi/prod2/{media,game}/<region>/<name> for the EC2 boxes' CloudWatch agent."
  type        = list(string)
  default     = ["container", "syslog", "bootstrap"]
}

# Alarm thresholds
variable "rds_cpu_high_pct" {
  type    = number
  default = 80
}

variable "rds_free_storage_low_bytes" {
  type    = number
  default = 2147483648 # 2 GiB
}

variable "rds_freeable_memory_low_bytes" {
  type    = number
  default = 134217728 # 128 MiB
}

variable "rds_connections_high" {
  description = "db.t4g.small allows ~200 connections."
  type        = number
  default     = 160
}

variable "valkey_memory_high_pct" {
  description = "noeviction: writes FAIL at 100 %, so warn early."
  type        = number
  default     = 75
}

variable "alb_5xx_per_5min" {
  type    = number
  default = 20
}
