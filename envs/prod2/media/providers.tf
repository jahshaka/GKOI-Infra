locals {
  tags = {
    project      = "gkoi"
    env          = "prod2"
    "managed-by" = "terraform"
    stack        = "media"
  }
}

# Home (us-west-2): the usw2 box, the engine's internal ALB, the secrets, the bundle objects, the Valkey rule.
provider "aws" {
  region              = "us-west-2"
  allowed_account_ids = [var.account_id]
  default_tags { tags = local.tags }
}

provider "aws" {
  alias               = "euc1"
  region              = "eu-central-1"
  allowed_account_ids = [var.account_id]
  default_tags { tags = local.tags }
}

provider "aws" {
  alias               = "use1"
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]
  default_tags { tags = local.tags }
}

# Tokyo (apne1) is PAUSED in modules/regions: when it is enabled, add its provider + a module "box_apne1" block here
# (copy box_use1) and an `apne1` entry in var.media_regions.
