variable "cluster_id" {
  type    = string
  default = "campuscart-redis"
}

variable "node_type" {
  description = "ElastiCache node size. cache.t3.micro is Free Tier eligible."
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  type    = string
  default = "7.1"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "eks_node_security_group_id" {
  type = string
}
