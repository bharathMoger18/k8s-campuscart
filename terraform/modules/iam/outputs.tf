# =============================================================================
# terraform/modules/iam/outputs.tf
# =============================================================================
output "cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role."
  value       = aws_iam_role.eks_cluster.arn
}

output "node_role_arn" {
  description = "ARN of the EKS node group IAM role."
  value       = aws_iam_role.eks_node.arn
}
