terraform {
  required_version = ">= 1.6.0"

  # Hetzner Object Storage (S3-compatible). All connection details are
  # supplied by the workflow via -backend-config; credentials come from
  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars.
  backend "s3" {}

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

# Token from HCLOUD_TOKEN env var.
provider "hcloud" {}
