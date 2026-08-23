# =============================================================================
# terraform/bootstrap/provider.tf
# =============================================================================
# WHY THIS FILE EXISTS ON ITS OWN:
# Every Terraform "root module" (a folder you run `terraform init/apply` in)
# needs to declare which provider(s) it talks to, and which versions are
# acceptable. We isolate this into its own file purely for readability —
# Terraform doesn't care how many .tf files you split things into; it reads
# every *.tf file in the directory as one combined configuration.
# =============================================================================

terraform {
  # required_version pins the Terraform CLI version itself. Without this,
  # a teammate on a newer/older Terraform binary could apply this code and
  # get subtly different behavior. Pinning is a production best practice —
  # "works on my machine" is not acceptable for infrastructure.
  # Bumped from 1.7.0 → 1.10.0: native S3 locking (use_lockfile) was only
  # added in Terraform 1.10, released Nov 2024. Without this minimum, a
  # teammate on an older Terraform binary would fail to lock state at all.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # We pin to the 5.x major version line, but allow any minor/patch
      # update within it (the ~> operator means "5.x, but not 6.0").
      # This gets us bug fixes automatically without risking breaking changes.
      version = "~> 5.0"
    }
  }

  # -----------------------------------------------------------------------
  # NOTE: There is deliberately NO `backend` block in this file.
  # This is the ONE Terraform root module in our entire project that uses
  # LOCAL state (a terraform.tfstate file sitting on your own disk).
  #
  # Why? Because this module's entire JOB is to CREATE the S3 bucket that
  # every OTHER module will store ITS state in. You cannot point Terraform
  # at a remote backend that doesn't exist yet — chicken, meet egg.
  #
  # This local state file is small, short-lived (you run this once, maybe
  # twice ever), and low-risk. We still won't commit it to git — see
  # .gitignore instructions in the README in this folder.
  # -----------------------------------------------------------------------
}

provider "aws" {
  region = var.aws_region

  # default_tags automatically stamps every single resource this provider
  # creates with these tags — no exceptions, no forgetting. In a real AWS
  # bill with hundreds of resources across multiple projects, this is what
  # lets you (or a Cost Explorer report) answer "which resources belong to
  # CampusCart?" in one filter, instead of guessing from resource names.
  default_tags {
    tags = {
      Project     = "campuscart"
      ManagedBy   = "terraform"
      Environment = "bootstrap"
    }
  }
}
