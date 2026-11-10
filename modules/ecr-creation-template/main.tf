# A repository creation template in a REPLICATION destination region, so the replicas ECR creates for `gkoi/*`
# get the same tag immutability and lifecycle as the source repos (otherwise they would be mutable and never
# expire). Scan-on-push is not a template setting (it is per-registry); the images are scanned in us-west-2 on
# push. No resource tags in the template: tags would need a custom role.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
  }
}

variable "prefix" {
  type = string
}

variable "lifecycle_policy" {
  type = string
}

resource "aws_ecr_repository_creation_template" "this" {
  prefix               = var.prefix
  description          = "GKOI prod2 replicas (managed by Terraform, registry stack)"
  applied_for          = ["REPLICATION"]
  image_tag_mutability = "IMMUTABLE"
  lifecycle_policy     = var.lifecycle_policy

  encryption_configuration {
    encryption_type = "AES256"
  }
}
