# =============================================================================
# terraform/environments/production/outputs.tf
# =============================================================================
# WHY WE RE-EXPOSE MODULE OUTPUTS HERE:
# module.networking.vpc_id already exists and is directly usable by other
# module blocks we'll add in THIS SAME main.tf (like `module "eks"`)
# without needing an output at all — modules in the same root module can
# reference each other's outputs directly.
#
# So why declare these here too? Two real reasons:
#   1. Human visibility — running `terraform output` after apply shows you
#      these values on screen, useful for debugging or manually verifying
#      things (e.g. checking the VPC ID in the AWS Console).
#   2. CI/CD pipelines (like our future Jenkinsfile.aws) can read these
#      via `terraform output -json` to feed values into later pipeline
#      steps, like configuring kubectl to talk to the right cluster.
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC created for this environment."
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs — where the ALB will live."
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs — where EKS nodes, RDS, and ElastiCache will live."
  value       = module.networking.private_subnet_ids
}


output "eks_cluster_role_arn" {
  description = "IAM role ARN the EKS module will use to create the cluster."
  value       = module.iam.cluster_role_arn
}

output "eks_node_role_arn" {
  description = "IAM role ARN the EKS module will use for worker nodes."
  value       = module.iam.node_role_arn
}

output "eks_cluster_name" {
  description = "EKS cluster name — you'll use this with: aws eks update-kubeconfig --name <this>"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "eks_oidc_provider_arn" {
  description = "OIDC provider ARN — needed later for the ALB Controller's IRSA role."
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "OIDC provider URL (no https:// prefix) — needed later for IRSA trust policies."
  value       = module.eks.oidc_provider_url
}


output "ecr_repository_urls" {
  description = "Map of image name -> ECR URL, used by Jenkinsfile.aws for docker push, and by k8s-aws manifests for image references."
  value       = module.ecr.repository_urls
}

output "db_endpoint" {
  description = "Postgres connection endpoint for Django's DATABASE_URL."
  value       = module.rds.db_endpoint
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the DB password — fetch at runtime, never hardcode."
  value       = module.rds.db_secret_arn
}

output "redis_endpoint" {
  description = "Redis endpoint for Django Channels' CHANNEL_LAYERS config and cache backend."
  value       = module.elasticache.redis_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA cert — needed by the addons module's kubernetes/helm providers."
  value       = module.eks.cluster_certificate_authority_data
}
