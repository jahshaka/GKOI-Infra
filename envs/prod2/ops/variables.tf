variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

# App → database, its ONE role and the secret holding that role's password. The SAME triples as db-restore's `apps`
# (and the compute stack's env + secrets): the ops task connects exactly as the service does — never as the RDS master.
variable "apps" {
  type = map(object({
    db        = string
    role      = string
    pw_secret = string
  }))
  default = {
    cms    = { db = "aisolver_cms", role = "cms", pw_secret = "gkoi/prod2/cms/DB_PASSWORD" }
    engine = { db = "mikaido", role = "mikaido_app", pw_secret = "gkoi/prod2/engine/POSTGRES_APP_PASSWORD" }
    fm     = { db = "filemanager", role = "filemanager_app", pw_secret = "gkoi/prod2/fm/POSTGRES_APP_PASSWORD" }
  }
}

variable "postgres_image_tag" {
  description = "gkoi/ci-postgres: postgres:16.15-alpine (the mirror db-restore uses). The plan resolves it to its digest."
  type        = string
  default     = "16.15-alpine"
}

variable "log_retention_days" {
  description = "The task log holds query RESULTS (base64), read back by prod-psql.sh within seconds: keep it short."
  type        = number
  default     = 1
}

variable "max_seconds" {
  description = "Wall clock for one psql run inside the task (busybox timeout); the task stops itself after it."
  type        = number
  default     = 300
}

variable "statement_ms" {
  description = "statement_timeout for every statement the task runs."
  type        = number
  default     = 120000
}

variable "task_size" {
  type = object({
    cpu    = number
    memory = number
  })
  default = { cpu = 256, memory = 512 }
}
