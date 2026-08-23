# =============================================================================
# terraform/modules/eks/main.tf
# =============================================================================

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn # the "who is this control plane allowed to act as" role from our iam module
  version  = var.kubernetes_version

  # -----------------------------------------------------------------------
  # NEW: explicitly enable API-based access management. Without this, EKS
  # defaults to a mode that doesn't support Access Entries at all — which
  # is exactly what caused the error you just hit. "API_AND_CONFIG_MAP"
  # supports BOTH the modern Access Entry API (what we're using) AND the
  # older aws-auth ConfigMap approach, for maximum compatibility.
  # -----------------------------------------------------------------------
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true # explicitly matches the existing value — prevents the ForceNew trigger we just hit
  }


  vpc_config {
    # EKS needs BOTH public and private subnets listed here — the control
    # plane places elastic network interfaces (ENIs) into these subnets to
    # communicate with your worker nodes, regardless of whether the API
    # endpoint itself is public or private.
    subnet_ids = concat(var.private_subnet_ids, var.public_subnet_ids)

    # endpoint_public_access = true means YOUR laptop's kubectl can reach
    # the cluster's API server directly over the internet (with IAM auth
    # still required — public reachability isn't the same as public
    # permission). This is genuinely convenient for learning/testing.
    #
    # In a hardened production setup, teams often set this to FALSE and
    # instead require a VPN or bastion host into the VPC — but that adds
    # real operational complexity we don't need for this build. We're
    # choosing public access deliberately, not out of laziness — it's the
    # right trade-off for what we're doing right now.
    endpoint_public_access = var.endpoint_public_access

    # Private access stays TRUE regardless — this lets resources INSIDE
    # the VPC (like the worker nodes themselves) reach the API server
    # without their traffic ever leaving AWS's internal network, which is
    # both faster and more secure than routing node-to-control-plane
    # traffic out over the public internet.
    endpoint_private_access = true
  }

  # Control plane logging — sends these log types to CloudWatch. This is
  # a genuine production best practice: if something goes wrong with
  # authentication or scheduling, these logs are often the only way to
  # diagnose it, since you have no direct server access to the control
  # plane to check logs any other way.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "scheduler", "controllerManager"]

  # This ensures the IAM role and its policy attachment fully exist
  # before EKS tries to use them — a role that exists but hasn't
  # finished attaching its policy could cause cluster creation to fail.
  depends_on = [var.cluster_role_arn]

  tags = {
    Name = var.cluster_name
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 2: EKS Managed Node Group
# -----------------------------------------------------------------------------
# "Managed" here means AWS handles the underlying EC2 lifecycle for you —
# provisioning instances into an Auto Scaling Group, draining nodes safely
# during updates, and integrating with EKS's own APIs — vs. a "self-managed
# node group" where you'd write your own Auto Scaling Group and launch
# template from scratch. Managed is the sensible default unless you need
# very specific customization.
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = var.node_role_arn

  # DELIBERATE: only private subnets. Worker nodes never get a public IP
  # or a route straight to the Internet Gateway — this is the payoff of
  # everything we built in the networking module. Pods run in a subnet
  # that cannot be reached FROM the internet, only reaches OUT via NAT.
  subnet_ids = var.private_subnet_ids

  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # update_config controls how many nodes can be unavailable AT ONCE during
  # a rolling update (e.g. a Kubernetes version bump). max_unavailable = 1
  # means "update one node at a time" — slower, but guarantees you never
  # lose more than one node's worth of capacity mid-update. This matters
  # for genuinely production-grade rollout safety.
  update_config {
    max_unavailable = 1
  }

  # This dependency isn't inferred automatically because node_role_arn is
  # just a string (the ARN), not a direct Terraform resource reference —
  # so we're explicit that the role's POLICY ATTACHMENTS must finish
  # first, or nodes could try to join the cluster before they actually
  # have the AmazonEKS_CNI_Policy permissions they need to get networking.
  depends_on = [aws_eks_cluster.main]

  tags = {
    Name = "${var.cluster_name}-node-group"
  }
}

# -----------------------------------------------------------------------------
# RESOURCE 3: Fetch the TLS certificate thumbprint of EKS's OIDC issuer
# -----------------------------------------------------------------------------
# This is another DATA SOURCE (reads existing info, creates nothing). Every
# EKS cluster automatically exposes its own OIDC issuer URL the moment it's
# created — we don't create the issuer ourselves, we just need its
# certificate's thumbprint to register AWS IAM's TRUST in it.
# -----------------------------------------------------------------------------
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# -----------------------------------------------------------------------------
# RESOURCE 4: Register that OIDC issuer as a trusted identity provider in IAM
# -----------------------------------------------------------------------------
# This is the actual "trust bridge" from the diagram. After this resource
# exists, AWS IAM is willing to trust tokens issued by THIS cluster's OIDC
# endpoint — meaning a Kubernetes ServiceAccount token from this specific
# cluster can be exchanged for temporary AWS credentials, scoped to
# whatever IAM role that ServiceAccount is mapped to.
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list  = ["sts.amazonaws.com"] # the AWS service that will consume these tokens
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}
