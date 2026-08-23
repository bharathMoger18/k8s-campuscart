# =============================================================================
# terraform/environments/production/variables.tf
# =============================================================================
# This file will grow as we add modules (networking, EKS, RDS, etc.) — each
# new module we wire in will need its own inputs declared here. For now, it
# holds exactly one variable: the one provider.tf already references.
# =============================================================================

variable "aws_region" {
  description = "AWS region for all production infrastructure."
  type        = string
  default     = "ap-south-1" # Mumbai — our agreed region for this project
}
# ... (aws_region variable from before stays as-is) ...

variable "cluster_name" {
  description = "Name for the EKS cluster — also used to tag VPC subnets for EKS auto-discovery."
  type        = string
  default     = "campuscart-eks"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets across."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "single_nat_gateway" {
  description = "Cost-optimized single NAT gateway vs one-per-AZ redundancy."
  type        = bool
  default     = true
}


variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "EC2 instance types for worker nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "SPOT or ON_DEMAND."
  type        = string
  default     = "SPOT"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}
