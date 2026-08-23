# =============================================================================
# terraform/environments/production-addons/variables.tf
# =============================================================================
# This root module needs far fewer variables than environments/production/,
# since almost everything it needs (cluster name, OIDC info, VPC ID, DB
# secret ARN) comes from CORE's outputs via terraform_remote_state, not
# from variables passed in directly. This is genuinely the only one it
# needs on its own.
# =============================================================================

variable "aws_region" {
  description = "AWS region — must match where core infrastructure was provisioned."
  type        = string
  default     = "ap-south-1"
}
