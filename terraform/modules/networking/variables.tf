# =============================================================================
# terraform/modules/networking/variables.tf
# =============================================================================
# WHY THIS IS A "MODULE", NOT A ROOT MODULE:
# Unlike bootstrap/ and environments/production/, this folder will never
# have `terraform apply` run inside it directly. It's a reusable BUILDING
# BLOCK — environments/production/main.tf will "call" this module, passing
# in values for these variables. This is what lets the same networking
# code be reused for a staging environment later, just with different
# variable values, instead of copy-pasting the whole VPC setup again.
# =============================================================================

variable "vpc_cidr" {
  description = "The IP address range for the entire VPC, in CIDR notation."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to spread subnets across. Two is the production minimum for real failover."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ, same order as availability_zones."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, one per AZ, same order as availability_zones."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "cluster_name" {
  description = "Name of the EKS cluster that will live in this VPC — used to tag subnets so EKS and its load balancer controller can auto-discover them."
  type        = string
  default     = "campuscart-eks"
}



variable "single_nat_gateway" {
  description = "If true, create ONE NAT gateway (cost-optimized, single point of failure). If false, create one NAT gateway PER AZ (full production redundancy, roughly double the cost)."
  type        = bool
  default     = true # cost-optimized for our test-and-destroy workflow
}
