# =============================================================================
# terraform/environments/production/main.tf
# =============================================================================
# This is where we start ASSEMBLING the real infrastructure by CALLING our
# reusable modules. This file will grow as we add eks, rds, elasticache,
# ecr — each becomes one more `module` block here, wired to the outputs of
# the modules before it.
# =============================================================================

module "networking" {
  source = "../../modules/networking"

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  cluster_name         = var.cluster_name
  single_nat_gateway   = var.single_nat_gateway
}


module "iam" {
  source = "../../modules/iam"

  cluster_name = var.cluster_name
}


module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # ---------------------------------------------------------------------
  # THIS is the moment our earlier "Terraform builds a dependency graph"
  # flashcard becomes concrete and visible. Unlike the iam module, THIS
  # module block genuinely references OTHER modules' outputs directly:
  # ---------------------------------------------------------------------
  cluster_role_arn   = module.iam.cluster_role_arn
  node_role_arn      = module.iam.node_role_arn
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  public_subnet_ids  = module.networking.public_subnet_ids

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}


module "ecr" {
  source = "../../modules/ecr"

  repository_names = ["campuscart-backend", "campuscart-nginx"]
}

module "rds" {
  source = "../../modules/rds"

  identifier                 = "campuscart-db"
  vpc_id                     = module.networking.vpc_id
  private_subnet_ids         = module.networking.private_subnet_ids
  eks_node_security_group_id = module.eks.cluster_security_group_id
}

module "elasticache" {
  source = "../../modules/elasticache"

  cluster_id                 = "campuscart-redis"
  vpc_id                     = module.networking.vpc_id
  private_subnet_ids         = module.networking.private_subnet_ids
  eks_node_security_group_id = module.eks.cluster_security_group_id
}

# -----------------------------------------------------------------------------
# EKS Access Entry — the bridge between an IAM identity and Kubernetes RBAC.
# Without this, our Jenkins CI IAM user could authenticate to AWS fine, run
# `aws eks update-kubeconfig` fine, but every single kubectl command would
# fail with "Unauthorized" the moment it actually tried to talk to the
# Kubernetes API — a genuinely confusing failure mode if you don't know this
# second authorization layer exists.
# -----------------------------------------------------------------------------
resource "aws_eks_access_entry" "jenkins_ci" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::021859068764:user/jenkins-campuscart-ci" # the exact IAM user Jenkins authenticates as
}

# -----------------------------------------------------------------------------
# Associating a POLICY with that access entry — this is where we decide WHAT
# the Jenkins user can actually do once connected. AWS ships several
# predefined "EKS access policies" mirroring common Kubernetes RBAC
# ClusterRoles. We're using the admin policy here since Jenkins genuinely
# needs to create/update Deployments, Services, Ingress, Secrets across our
# whole app — but scoped to OUR namespace only, not cluster-wide, via the
# access_scope block below.
# -----------------------------------------------------------------------------
resource "aws_eks_access_policy_association" "jenkins_ci_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.jenkins_ci.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["campuscart"] # least privilege again — Jenkins can't touch kube-system, other namespaces, anything outside its own app
  }
}
