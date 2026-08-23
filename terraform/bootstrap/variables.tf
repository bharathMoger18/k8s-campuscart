# =============================================================================
# terraform/bootstrap/variables.tf
# =============================================================================
# WHY VARIABLES INSTEAD OF HARDCODED VALUES:
# A senior engineer's rule of thumb: if a value could plausibly be different
# in another environment (staging vs production), another region, or another
# person's fork of this repo — it becomes a variable, never a hardcoded
# literal buried in a resource block. This is what makes Terraform code
# REUSABLE instead of a one-off script.
# =============================================================================

variable "aws_region" {
  description = "AWS region where the state bucket lives. Should match the region of the actual infrastructure for lowest latency, though technically state storage location is independent."
  type        = string
  default     = "ap-south-1" # Mumbai — matches our decision for the whole project
}

variable "state_bucket_name" {
  description = <<-EOT
    Globally unique S3 bucket name for storing Terraform state.
    S3 bucket names are unique across ALL of AWS, not just your account —
    so this MUST include something unique to you (like your AWS account ID
    or a random suffix), or bucket creation will fail if someone else in
    the world already took a generic name like "campuscart-state".
  EOT
  type        = string
  # No default on purpose — you MUST set this explicitly in terraform.tfvars,
  # as a deliberate forcing function so you think about uniqueness.
}
