locals {
  tags = {
    project      = "gkoi"
    env          = "prod2"
    "managed-by" = "terraform"
    stack        = "game"
  }
}

# Home (us-west-2): the usw2 box, the match-server key secret, the box bundle objects.
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

# Tokyo (ap-northeast-1): the apne1 game box (game_regions.apne1; README "Tokyo").
provider "aws" {
  alias               = "apne1"
  region              = "ap-northeast-1"
  allowed_account_ids = [var.account_id]
  default_tags { tags = local.tags }
}
