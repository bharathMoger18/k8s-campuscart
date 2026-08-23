# =============================================================================
# terraform/environments/production/provider.tf
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Notice: no access_key or secret_key written here, anywhere.
  # This is deliberate, and it's the single most important security habit
  # in this entire project — explained below.

  default_tags {
    tags = {
      Project     = "campuscart"
      ManagedBy   = "terraform"
      Environment = "production"
    }
  }
}
