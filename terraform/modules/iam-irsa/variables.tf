# =============================================================================
# terraform/modules/iam-irsa/variables.tf
# =============================================================================
# A GENERIC, REUSABLE module for "create an IRSA role for a specific
# Kubernetes ServiceAccount." We'll call this once for ESO now, and again
# later for the ALB Controller — same pattern, different inputs.
# =============================================================================

variable "role_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL, no https:// prefix."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the trusted ServiceAccount lives in."
  type        = string
}

variable "service_account_name" {
  type = string
}

variable "policy_json" {
  description = "The permission policy JSON this role should have — caller-provided, since every IRSA use case needs different permissions."
  type        = string
}
