# =============================================================================
# terraform/modules/iam/main.tf
# =============================================================================
# EKS needs TWO distinct IAM roles, for two distinct things that need AWS
# permissions:
#   1. The EKS CONTROL PLANE itself (AWS-managed, runs the API server, etcd,
#      scheduler) needs permissions to create/manage AWS resources on your
#      behalf — like network interfaces for your subnets.
#   2. The WORKER NODES (EC2 instances actually running your pods) need
#      permissions to register themselves with the cluster, pull container
#      images, and manage networking.
# These are separate identities with separate, minimal permission sets —
# this is the principle of LEAST PRIVILEGE in action: neither role can do
# what the other one does, because neither needs to.
#
# NOTE: The ESO and ALB Controller IRSA roles are NOT here — they live in
# modules/iam-irsa, called from environments/production-addons/, to avoid
# a circular dependency with the eks module's OIDC outputs.
# =============================================================================

# -----------------------------------------------------------------------------
# RESOURCE 1: Trust policy document for the EKS cluster role
# -----------------------------------------------------------------------------
# `aws_iam_policy_document` is a Terraform DATA SOURCE, not a resource — it
# doesn't create anything in AWS by itself. It's a convenience for
# generating correctly-formatted JSON policy documents using HCL syntax
# instead of hand-writing raw JSON (which is easy to get subtly wrong).
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"] # "sts" = Security Token Service — the AWS service that issues temporary credentials

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"] # ONLY the EKS service itself can assume this role — nothing else
    }
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 2: The EKS cluster IAM role itself
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_trust.json
}

# -----------------------------------------------------------------------------
# RESOURCE 3: Attach AWS's managed permission policy to that role
# -----------------------------------------------------------------------------
# WHY A "MANAGED" POLICY INSTEAD OF WRITING OUR OWN: AWS maintains and
# updates AmazonEKSClusterPolicy themselves as EKS's own internal needs
# evolve — writing a custom equivalent means YOU now own keeping it correct
# forever as AWS changes EKS internals. For AWS-service-facing roles like
# this one, using AWS's own managed policy is the standard, correct choice.
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------------------------------------------------------
# RESOURCE 4: Trust policy for the node group role
# -----------------------------------------------------------------------------
# Different principal this time — EC2, not EKS. Worker nodes ARE EC2
# instances, so it's the EC2 SERVICE that needs permission to assume this
# role on the instance's behalf when it boots up.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_node_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_trust.json
}

# -----------------------------------------------------------------------------
# RESOURCE 5, 6, 7: Three managed policies attached to the node role
# -----------------------------------------------------------------------------
# Worker nodes need THREE distinct permission sets, each doing a genuinely
# different job:
# -----------------------------------------------------------------------------

# Lets the node register itself with the EKS control plane, and lets the
# control plane manage the node (e.g. cordon/drain during updates).
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

# CNI = Container Networking Interface. EKS uses the AWS VPC CNI plugin,
# which assigns each POD its own real IP address FROM YOUR VPC's CIDR
# range (unlike many other Kubernetes networking setups that use an
# overlay network). This policy lets that plugin attach/manage the
# elastic network interfaces and IPs needed to make that work.
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Lets the node PULL container images from ECR. Notice it's "ReadOnly" —
# a worker node needs to DOWNLOAD images to run them, but has zero
# business being able to PUSH/overwrite images in your registry. That's
# least privilege again.
resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
