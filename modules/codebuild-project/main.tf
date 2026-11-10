# One app repo's CodeBuild project (C14): privileged (Docker), source = an S3 ZIP uploaded from our own checkout
# (never GitHub), its own /gkoi/ role allowed ONLY to read its source prefix, use its cache prefix, push its ECR
# repos and write its log group. The buildspec lives in the app repo (lane C).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
  }
}

variable "name" {
  description = "The repo name, e.g. aisolver-www."
  type        = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "source_bucket" {
  type = string
}

variable "source_key" {
  description = "Default source object; a release start overrides it per build (sourceLocationOverride)."
  type        = string
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "ecr_repository_names" {
  type = list(string)
}

variable "compute_type" {
  type    = string
  default = "BUILD_GENERAL1_LARGE"
}

variable "image" {
  type    = string
  default = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
}

variable "build_timeout_minutes" {
  type    = number
  default = 90
}

variable "log_retention_days" {
  type    = number
  default = 30
}

locals {
  project       = "gkoi-build-${var.name}"
  log_group     = "/gkoi/codebuild/${var.name}"
  bucket_arn    = "arn:aws:s3:::${var.source_bucket}"
  source_prefix = "${var.name}/"
  cache_prefix  = "cache/${var.name}/"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.project
  path               = "/gkoi/"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "this" {
  statement {
    sid       = "ReadOwnSource"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.bucket_arn}/${local.source_prefix}*"]
  }
  statement {
    sid       = "WriteOwnImageList"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/${local.source_prefix}*/images.json"]
  }
  statement {
    sid       = "OwnCache"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/${local.cache_prefix}*"]
  }
  statement {
    sid       = "ListOwnPrefixes"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.source_prefix}*", "${local.cache_prefix}*"]
    }
  }
  statement {
    sid       = "SourceBucketMeta"
    actions   = ["s3:GetBucketAcl", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushOwnRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = var.ecr_repository_arns
  }
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "build"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

resource "aws_codebuild_project" "this" {
  name                   = local.project
  description            = "Gate + build + push the ${var.name} images (source: s3://${var.source_bucket}/${var.source_key})"
  service_role           = aws_iam_role.this.arn
  build_timeout          = var.build_timeout_minutes
  queued_timeout         = 60
  concurrent_build_limit = 1

  source {
    type      = "S3"
    location  = "${var.source_bucket}/${var.source_key}"
    buildspec = "buildspec.yml"
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE"]
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = var.compute_type
    image           = var.image
    privileged_mode = true

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.account_id
    }
    environment_variable {
      name  = "ECR_REGISTRY"
      value = "${var.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    }
    environment_variable {
      name  = "ECR_REPOSITORIES"
      value = join(",", var.ecr_repository_names)
    }
    environment_variable {
      name  = "BUILD_CACHE_S3"
      value = "s3://${var.source_bucket}/${local.cache_prefix}"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.this.name
      status     = "ENABLED"
    }
    s3_logs {
      status = "DISABLED"
    }
  }

  depends_on = [aws_iam_role_policy.this]
}

output "project_name" {
  value = aws_codebuild_project.this.name
}

output "project_arn" {
  value = aws_codebuild_project.this.arn
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.this.name
}
