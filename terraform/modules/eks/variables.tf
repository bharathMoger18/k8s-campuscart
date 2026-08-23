variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "cluster_role_arn" {
  description = "IAM role ARN for the EKS control plane (from the iam module)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the cluster's networking lives in (from the networking module)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs — control plane ENIs and worker nodes both go here."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs — included so the control plane CAN reach public endpoint access if enabled."
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.31"
}

variable "endpoint_public_access" {
  description = "Whether the cluster API server is reachable from the public internet (needed for kubectl from your laptop)."
  type        = bool
  default     = true
}


variable "node_role_arn" {
  description = "IAM role ARN for worker nodes (from the iam module)."
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for worker nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "SPOT (cheaper, interruptible) or ON_DEMAND (guaranteed, pricier)."
  type        = string
  default     = "SPOT"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum worker nodes (floor for autoscaling)."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum worker nodes (ceiling for autoscaling)."
  type        = number
  default     = 3
}
