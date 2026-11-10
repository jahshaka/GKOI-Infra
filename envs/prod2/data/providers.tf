locals {
  tags = {
    project      = "gkoi"
    env          = "prod2"
    "managed-by" = "terraform"
    stack        = "data"
  }
}

provider "aws" {
  region              = "us-west-2"
  allowed_account_ids = [var.account_id]
  default_tags { tags = local.tags }
}
