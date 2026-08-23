# =============================================================================
# terraform/bootstrap/outputs.tf
# =============================================================================
# WHY OUTPUTS MATTER HERE SPECIFICALLY:
# After we apply this module once, we need to hand this exact value
# (bucket name) to every other module's `backend "s3"` block. Outputs are
# how a Terraform module "publishes" values for humans (or other modules,
# or CI pipelines) to read after an apply finishes. You'll literally copy
# this output value into environments/production/backend.tf in our next step.
# =============================================================================

output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state — copy this into every other module's backend config."
  value       = aws_s3_bucket.terraform_state.id
}
