# =============================================================================
# terraform/environments/production-addons/provider.tf
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# THIS is how we solve the chicken-and-egg problem: we don't reference the
# eks module directly (there IS no eks module in THIS root module). Instead
# we read the CORE infra's state file remotely — which by this point has
# ALREADY finished applying and contains real, concrete values, not
# something Terraform still needs to compute.
# -----------------------------------------------------------------------------
data "terraform_remote_state" "core" {
  backend = "s3"
  config = {
    bucket = "campuscart-tfstate-021859068764"
    key    = "environments/production/terraform.tfstate" # points at STAGE 1's state file
    region = "ap-south-1"
  }
}

# -----------------------------------------------------------------------------
# This data source calls AWS's own token-vending API to get a short-lived
# authentication token for the EKS cluster — the same mechanism `aws eks
# update-kubeconfig` uses under the hood. It's how Terraform itself
# authenticates to the cluster's API server, using your existing AWS
# credentials (the ~/.aws/credentials we confirmed you already have).
# -----------------------------------------------------------------------------
data "aws_eks_cluster_auth" "main" {
  name = data.terraform_remote_state.core.outputs.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.core.outputs.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.core.outputs.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.core.outputs.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.core.outputs.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}
