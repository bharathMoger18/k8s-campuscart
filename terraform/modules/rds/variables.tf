variable "identifier" {
  description = "Name/identifier for the RDS instance."
  type        = string
  default     = "campuscart-db"
}

variable "engine_version" {
  description = "PostgreSQL version."
  type        = string
  default     = "16.15"
}

variable "instance_class" {
  description = "RDS instance size. db.t3.micro is Free Tier eligible and plenty for a test/learning deployment."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage in GB."
  type        = number
  default     = 20
}

variable "db_name" {
  type    = string
  default = "campuscart"
}

variable "db_username" {
  type      = string
  default   = "campuscart_admin"
  sensitive = true
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "eks_node_security_group_id" {
  description = "The EKS node group's security group ID — the ONLY thing allowed to reach this database."
  type        = string
}
