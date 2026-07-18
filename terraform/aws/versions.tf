terraform {
  # 1.10+ for S3-native state locking (use_lockfile).
  required_version = ">= 1.10.0"

  # Bucket/key/region are supplied by the workflow via -backend-config;
  # credentials come from the configure-aws-credentials action.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region
}
