variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "state_bucket" {
  type    = string
  default = "gkoi-tfstate-127214190346"
}

variable "cluster_name" {
  description = "The ECS cluster the one-off restore runs in (the compute stack's). Read at RUN time only (run config)."
  type        = string
  default     = "gkoi-prod2"
}

variable "transit_bucket" {
  description = "The private transit bucket for dumps (created here): <app>/<UTC stamp>/<db>.dump + .sha256, SSE-S3, expired after transit_days."
  type        = string
  default     = "gkoi-prod2-db-transit-127214190346"
}

variable "transit_days" {
  type    = number
  default = 7
}

# App → database, its ONE role (the owner AND the role the services connect as — the repos' C-4 rule: mikaido +
# filemanager infra/postgres/app-role.sql, aisolver-www scripts/db/owner-role.sql) and the secret holding its password.
# MUST match the compute stack's env (env-defaults.tf: DB_NAME/DB_USER, POSTGRES_DB/POSTGRES_APP_USER) and its secrets.
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

variable "allow_generate_password" {
  description = "false (default): the restore only READS the app password secrets (they are filled by the orchestrator). true: the task role may also GetRandomPassword + PutSecretValue, and `gkoi-db-restore --generate-password` fills an EMPTY secret."
  type        = bool
  default     = false
}

# Mirrors pushed once by the orchestrator (registry extra_repositories; README "db-restore"). The plan resolves each
# tag to its digest (data.aws_ecr_image) and fails if it was not pushed.
variable "postgres_image_tag" {
  description = "gkoi/postgres: postgres:16.15-alpine (prod's 16.15), pulled by digest sha256:aa6cb33cf4c19c765cefcf48d96176258800870a9a1e930ad126200f9d825139."
  type        = string
  default     = "16.15-alpine"
}

variable "awscli_image_tag" {
  description = "gkoi/aws-cli: amazon/aws-cli:2.22.35 (the version gkoi-aws uses), digest sha256:6977c83ae3dc99f28fcf8276b9ea5eec33833cd5be40574b34112e98113ec7a2."
  type        = string
  default     = "2.22.35"
}

variable "db_lc_collate" {
  description = "LC_COLLATE of the created databases. C = byte order, which is what prod's postgres:16-alpine (musl: strcoll = strcmp) sorts by today."
  type        = string
  default     = "C"
}

variable "db_lc_ctype" {
  type    = string
  default = "en_US.UTF-8"
}

variable "task_size" {
  type = object({
    cpu    = number
    memory = number
  })
  default = { cpu = 512, memory = 1024 }
}
