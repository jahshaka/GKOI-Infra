variable "account_id" {
  type    = string
  default = "127214190346"
}

variable "source_bucket" {
  description = "EXISTING bucket the release tool uploads source ZIPs to (not managed here)."
  type        = string
  default     = "gkoi-build-sources-127214190346"
}

variable "keep_images" {
  description = "ECR lifecycle: keep the last N images per repo."
  type        = number
  default     = 20
}

# Plan §C14: one CodeBuild project per app repo; each pushes only its own ECR repos.
variable "build_projects" {
  type = map(object({
    repositories = list(string)
  }))
  default = {
    aisolver-www = {
      repositories = ["cms-server", "cms-nginx"]
    }
    mikaido = {
      repositories = ["engine-api", "engine-edge", "engine-worker", "engine-web", "media-agent", "media-origin", "mediamtx"]
    }
    filemanager = {
      repositories = ["fm-api", "fm-worker", "fm-web"]
    }
    warroom-game = {
      repositories = ["warroom-game"]
    }
  }
}

variable "extra_repositories" {
  description = "Repos no build project pushes: ci-minio = our pinned copy of the MinIO test image (gone from Docker Hub), pushed once by the orchestrator."
  type        = list(string)
  default     = ["ci-minio"]
}
