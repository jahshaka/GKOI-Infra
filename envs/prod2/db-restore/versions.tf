terraform {
  required_version = "= 1.9.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
  }

  backend "s3" {
    bucket         = "gkoi-tfstate-127214190346"
    key            = "prod2/db-restore/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "gkoi-tflock"
    encrypt        = true
  }
}
