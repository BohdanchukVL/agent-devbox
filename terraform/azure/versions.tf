terraform {
  required_version = ">= 1.6.0"

  # Storage account/container are supplied by the workflow via
  # -backend-config; auth via ARM_ACCESS_KEY exported by the bootstrap step.
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# Auth via the Azure CLI session established by azure/login;
# subscription id from the ARM_SUBSCRIPTION_ID env var.
provider "azurerm" {
  features {}
}
