variable "repository_names" {
  description = "Names of ECR repositories to create — one per container image your app needs."
  type        = list(string)
  # Based on your docker-compose.yml and Dockerfiles, you likely need at
  # least: the Django backend, and the Nginx frontend. Adjust this list to
  # match your actual images once we look at your Dockerfiles together.
  default = ["campuscart-backend", "campuscart-nginx"]
}
