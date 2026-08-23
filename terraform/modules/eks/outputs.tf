output "cluster_name" {
  description = "EKS cluster name — needed for kubectl config and later modules."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "The Kubernetes API server endpoint URL."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "The cluster's CA cert, base64-encoded — needed by kubectl/Terraform's kubernetes provider to trust the API server's TLS."
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — needed by any future IRSA role's trust policy (e.g. for the ALB Controller)."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "The OIDC issuer URL without the https:// prefix — IAM trust policies for IRSA roles need this exact format."
  value       = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

output "cluster_security_group_id" {
  description = "The security group EKS automatically creates and attaches to both the control plane AND all managed node group instances — this is what RDS/ElastiCache security groups will reference as their allowed source."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
