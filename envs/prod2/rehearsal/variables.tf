variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

variable "driver_image" {
  description = <<-EOT
    The driver's image: Node 22 on Alpine from ECR Public (Docker's official library mirror — no Docker Hub, no ECR
    auth); entrypoint.sh adds Alpine's ffmpeg (6.1: libx264, lavfi, AAC, rtmps) at start through the NAT. Pinned by
    digest (checked 2026-11-11: node:22.11.0-alpine3.20 = this digest).
  EOT
  type        = string
  default     = "public.ecr.aws/docker/library/node@sha256:b64ced2e7cd0a4816699fe308ce6e8a08ccba463c757c00c14cd372e3d2c763e"
}

variable "task_size" {
  description = "Fargate size. The 10 s 1080p60 clip takes ~10 CPU-seconds to encode once; publishing is -c copy (no CPU)."
  type = object({
    cpu    = number
    memory = number
  })
  default = { cpu = 2048, memory = 4096 }
}

variable "engine_url" {
  description = "The engine's public name (TLS SNI + Host). The driver CONNECTS to edge-alb's ALB instead (engine.gkoi.com's DNS still names Lightsail until the window)."
  type        = string
  default     = "https://engine.gkoi.com"
}

variable "cms_user_id" {
  description = "The test identity the driver signs (README 'The test user'): a cmsUserId no CMS user can have (the CMS's ids are numeric)."
  type        = string
  default     = "rehearsal-p2-driver"
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{8,64}$", var.cms_user_id)) && !can(regex("^[0-9]+$", var.cms_user_id))
    error_message = "cms_user_id: 8-64 of [A-Za-z0-9_-], not all digits (a CMS user id is numeric)."
  }
}

variable "publish_seconds" {
  type    = number
  default = 60
}

variable "video_kbps" {
  description = "The synthetic stream's video bitrate (the 1080p60 floor at the streamers' default 6 Mb/s)."
  type        = number
  default     = 6000
}

variable "origin_verify_secret_pattern" {
  description = "Each region's X-Origin-Verify secret (the media stack's origin_verify_secret default); %s = the region key."
  type        = string
  default     = "gkoi/media/%s/origin-verify"
}

variable "origin_verify_secret_json_key" {
  description = "As the media stack's: \"\" = the secret string IS the value."
  type        = string
  default     = ""
}

variable "gateway_secret_name" {
  description = "The engine's gateway secret (compute created it; the driver signs identities with it inside the task)."
  type        = string
  default     = "gkoi/prod2/engine/GATEWAY_SHARED_SECRET"
}

variable "log_retention_days" {
  type    = number
  default = 14
}
