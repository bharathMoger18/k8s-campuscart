# =============================================================================
# terraform/modules/iam/variables.tf
# =============================================================================
# WHY VARIABLES INSTEAD OF HARDCODED VALUES:
# A senior engineer's rule of thumb: if a value could plausibly be different
# in another environment (staging vs production), another region, or another
# person's fork of this repo — it becomes a variable, never a hardcoded
# literal buried in a resource block. This is what makes Terraform code
# REUSABLE instead of a one-off script.
#
# NOTE: This module ONLY handles the EKS cluster role and node role. The
# ESO/ALB Controller IRSA roles live in modules/iam-irsa instead, called
# from terraform/environments/production-addons/ — NOT here — because they
# need the EKS module's OIDC outputs, which would create a circular
# dependency if referenced inside this module (this module is called
# BEFORE eks, inside the SAME apply, in environments/production/main.tf).
# =============================================================================

variable "cluster_name" {
  description = "Name of the EKS cluster — used to name IAM roles consistently."
  type        = string
}


variable "oidc_provider_arn" {
  description = "OIDC provider ARN from the eks module — the IRSA trust bridge."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL (no https:// prefix) from the eks module."
  type        = string
}

variable "secret_arns" {
  description = "Specific Secrets Manager ARNs the ESO role is allowed to read — kept explicit and narrow, never a wildcard."
  type        = list(string)
}
