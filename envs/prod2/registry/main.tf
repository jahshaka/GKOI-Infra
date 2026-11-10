# Stage 1 — registry: the gkoi/* ECR repos (immutable tags, scan on push, keep the last N), replication to the
# enabled media/game regions, and one CodeBuild project + role per app repo (C14).

module "regions" {
  source = "../../../modules/regions"
}

locals {
  r = module.regions.all

  repo_names = sort(distinct(concat(flatten([for p in values(var.build_projects) : p.repositories]), var.extra_repositories)))

  lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${var.keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_images
      }
      action = { type = "expire" }
    }]
  })

  replica_regions = [for k, v in module.regions.edge_enabled : v.region]
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(local.repo_names)
  name                 = "gkoi/${each.value}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy     = local.lifecycle_policy
}

# NOTE: ECR replication is ONE registry-wide setting per account+region. This resource OWNS it: any replication
# rule already configured in us-west-2 would be replaced (check before the first apply — README "registry").
resource "aws_ecr_replication_configuration" "this" {
  count = length(local.replica_regions) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = local.replica_regions
        content {
          region      = destination.value
          registry_id = var.account_id
        }
      }
      repository_filter {
        filter      = "gkoi/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }

  depends_on = [
    module.template_euc1,
    module.template_use1,
    module.template_apne1,
  ]
}

module "template_euc1" {
  source           = "../../../modules/ecr-creation-template"
  count            = local.r.euc1.enabled ? 1 : 0
  providers        = { aws = aws.euc1 }
  prefix           = "gkoi"
  lifecycle_policy = local.lifecycle_policy
}

module "template_use1" {
  source           = "../../../modules/ecr-creation-template"
  count            = local.r.use1.enabled ? 1 : 0
  providers        = { aws = aws.use1 }
  prefix           = "gkoi"
  lifecycle_policy = local.lifecycle_policy
}

module "template_apne1" {
  source           = "../../../modules/ecr-creation-template"
  count            = local.r.apne1.enabled ? 1 : 0
  providers        = { aws = aws.apne1 }
  prefix           = "gkoi"
  lifecycle_policy = local.lifecycle_policy
}

# --- CodeBuild, one project per app repo ----------------------------------------------------------------------

module "build" {
  source   = "../../../modules/codebuild-project"
  for_each = var.build_projects

  name          = each.key
  account_id    = var.account_id
  region        = "us-west-2"
  source_bucket = var.source_bucket
  source_key    = "${each.key}/source.zip"

  ecr_repository_names = [for r in each.value.repositories : aws_ecr_repository.this[r].name]
  ecr_repository_arns  = [for r in each.value.repositories : aws_ecr_repository.this[r].arn]
}
