output "repository_urls" {
  description = "Map of repository name -> full ECR repository URL, needed for docker push/pull and for k8s manifest image references."
  value       = { for name, repo in aws_ecr_repository.repos : name => repo.repository_url }
}
