# =============================================================================
# terraform/environments/production/backend.tf
# =============================================================================
# This is where THIS module (and everything we build under environments/
# production/) stores its Terraform state — remotely, in the S3 bucket
# created by terraform/bootstrap/, with native S3 locking so it's safe
# even if two applies happen at once.
# =============================================================================

terraform {
  backend "s3" {
    # This MUST match the state_bucket_name output from `bootstrap/`.
    # Run `terraform output` inside terraform/bootstrap/ to get the exact
    # value, then paste it here manually — backend blocks cannot reference
    # variables or other resources, they have to be hardcoded literals.
    # This is a real Terraform limitation, not an oversight on our part.
    bucket = "campuscart-tfstate-021859068764"

    # The "key" is the actual filename/path INSIDE that bucket where this
    # specific module's state will live. Different modules get different
    # keys, so their state files don't collide with each other inside the
    # same bucket.
    key = "environments/production/terraform.tfstate"

    region = "ap-south-1"

    # THIS is the modern replacement for the old dynamodb_table = "..."
    # line. It tells the S3 backend to use S3's own conditional-write
    # locking (Terraform 1.10+) instead of a separate DynamoDB table.
    use_lockfile = true

    # Encrypts the state file itself using the bucket's default encryption
    # (the AES256 setting we configured back in bootstrap/main.tf).
    encrypt = true
  }
}
