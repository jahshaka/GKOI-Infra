locals {
  tags = {
    project      = "gkoi"
    env          = "prod2"
    "managed-by" = "terraform"
    stack        = "observability"
  }
}

# Every region has an aliased provider even when paused (a paused region's modules have count = 0).
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

provider "aws" {
  alias               = "apne1"
  region              = "ap-northeast-1"
  allowed_account_ids = [var.account_id]
  default_tags { tags = local.tags }
}
