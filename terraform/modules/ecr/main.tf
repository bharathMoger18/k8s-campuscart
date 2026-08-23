# =============================================================================
# terraform/modules/ecr/main.tf
# =============================================================================

# -----------------------------------------------------------------------------
# RESOURCE 1: One ECR repository per image, using for_each (not count)
# -----------------------------------------------------------------------------
# WHY for_each INSTEAD OF count HERE: count is index-based — if you ever
# reorder or remove an item from the middle of a list, Terraform can get
# confused about which resource maps to which index, sometimes causing it
# to destroy and recreate things that didn't actually need to change.
# for_each is KEY-based — each repository is tracked by its NAME, not its
# position in a list. Reordering the list, or adding a third repo, doesn't
# disturb the two that already exist. This is the modern best practice for
# any set of "named things," which repository names clearly are.
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "repos" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 2: Lifecycle policy — automatically clean up old images
# -----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 10 images, expire the rest"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
