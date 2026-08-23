# =============================================================================
# terraform/bootstrap/main.tf
# =============================================================================
# This module creates exactly one thing: an S3 bucket to store
# terraform.tfstate files for every OTHER module.
#
# You will run `terraform apply` in THIS folder exactly once (or rarely —
# e.g. if you ever needed to recreate the backend). Everything after this
# module references this bucket via a `backend "s3" {}` block.
# =============================================================================

# -----------------------------------------------------------------------------
# RESOURCE 1: The S3 bucket itself
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  # This is a genuine safety net, not decoration. If someone (including
  # future-you, tired, at 1am) runs `terraform destroy` against this
  # bootstrap module by mistake, this lifecycle rule makes Terraform
  # REFUSE to delete the bucket — you'd have to manually remove this
  # protection first. Losing your state bucket means Terraform "forgets"
  # every resource it ever created for you, which is a genuinely bad day.
  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 2: Versioning on that bucket
# -----------------------------------------------------------------------------
# WHY THIS MATTERS: Every time Terraform writes state, it OVERWRITES the
# state file. Without versioning, a bad apply that corrupts your state has
# no undo button. With versioning on, S3 keeps every prior version of the
# file — so if today's state gets mangled, you can literally download
# yesterday's version and recover. This is your state file's "backup
# history," and it costs practically nothing (a few KB/version).
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 3: Server-side encryption at rest
# -----------------------------------------------------------------------------
# WHY THIS MATTERS: Terraform state files often contain sensitive data in
# PLAINTEXT — database passwords, private keys, connection strings — because
# state records the actual attribute values of every resource, including
# ones you passed in as "sensitive" variables. AES256 encryption-at-rest
# means that even if someone somehow got raw access to the underlying S3
# storage (not just the bucket via IAM), the bytes are meaningless without
# the key. This is baseline hygiene for any bucket holding secrets.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 4: Block ALL public access — explicitly, at the bucket level
# -----------------------------------------------------------------------------
# WHY THIS MATTERS: This is arguably the single most common real-world AWS
# security incident: an S3 bucket accidentally left public, leaking secrets
# or data to the entire internet. Even though we never intend to make this
# bucket public, we don't rely on "intent" — we set an explicit guardrail
# that makes it structurally impossible, even if someone later fat-fingers
# a bucket policy. All four settings must be true to fully lock it down.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# NOTE: No DynamoDB table here anymore.
# -----------------------------------------------------------------------------
# As of Terraform 1.10+, the S3 backend supports NATIVE locking via S3's
# own conditional-write feature (If-None-Match), enabled with a single
# `use_lockfile = true` flag in each module's backend config. That gives us
# the same atomic "only one apply wins" guarantee DynamoDB used to provide —
# without a second AWS resource to create, secure, and pay for.
#
# We'll set `use_lockfile = true` in every module's backend.tf, starting
# with environments/production/backend.tf in the next step.
# -----------------------------------------------------------------------------
