# =============================================================================
# terraform/modules/networking/outputs.tf
# =============================================================================
# These are the exact values EKS, RDS, and ElastiCache modules will need —
# they don't know how to build a VPC, they just need to know WHICH VPC and
# WHICH subnets to launch into. This is the "return values" of our function.
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC — needed by EKS, RDS, and ElastiCache to know which network to launch into."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets — the ALB (Application Load Balancer) will be provisioned here."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets — EKS worker nodes, RDS, and ElastiCache will all live here."
  value       = aws_subnet.private[*].id
}

output "vpc_cidr_block" {
  description = "The VPC's CIDR block — used later for security group rules (e.g. 'allow traffic FROM anything inside this CIDR')."
  value       = aws_vpc.main.cidr_block
}
