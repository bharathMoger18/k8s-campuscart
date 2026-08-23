# -----------------------------------------------------------------------------
# The ESO permission policy — what secrets it's allowed to read. Built
# HERE, in the addons stage, because it references the RDS secret ARN,
# which is a CORE output, safely available now via remote state.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eso_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [data.terraform_remote_state.core.outputs.db_secret_arn]
  }
}

module "eso_irsa" {
  source = "../../modules/iam-irsa"

  role_name            = "campuscart-eso-role"
  oidc_provider_arn    = data.terraform_remote_state.core.outputs.eks_oidc_provider_arn
  oidc_provider_url    = data.terraform_remote_state.core.outputs.eks_oidc_provider_url
  namespace            = "external-secrets"
  service_account_name = "external-secrets-sa"
  policy_json          = data.aws_iam_policy_document.eso_permissions.json
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.10.4"

  set {
    name  = "serviceAccount.name"
    value = "external-secrets-sa" # MUST match service_account_name above, exactly — this is the string the IRSA trust condition checks against
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eso_irsa.role_arn
  }
}


# -----------------------------------------------------------------------------
# The ALB Controller's IAM policy is large and officially published/
# maintained by AWS themselves — dozens of specific EC2 and Elastic Load
# Balancing permissions. Rather than hand-copy and maintain that ourselves
# (and risk it silently going stale as AWS updates the controller), we
# fetch it directly from AWS's own published source at apply time.
# -----------------------------------------------------------------------------
data "http" "alb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.0/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name   = "campuscart-alb-controller-policy"
  policy = data.http.alb_controller_iam_policy.response_body
}

module "alb_controller_irsa" {
  source = "../../modules/iam-irsa"

  role_name            = "campuscart-alb-controller-role"
  oidc_provider_arn    = data.terraform_remote_state.core.outputs.eks_oidc_provider_arn
  oidc_provider_url    = data.terraform_remote_state.core.outputs.eks_oidc_provider_url
  namespace            = "kube-system"
  service_account_name = "aws-load-balancer-controller"
  policy_json          = aws_iam_policy.alb_controller.policy
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = data.terraform_remote_state.core.outputs.eks_cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_controller_irsa.role_arn
  }

  # Required so the controller knows which VPC to operate in — normally
  # auto-detected via the node's own metadata, but explicit is safer and
  # avoids a class of "works on some nodes, not others" bugs.
  set {
    name  = "vpcId"
    value = data.terraform_remote_state.core.outputs.vpc_id
  }
}


resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.1"
  # No IRSA needed here — metrics-server only talks to the Kubernetes API
  # itself (reading kubelet stats via the cluster's own network), never to
  # any AWS API directly. This is a genuinely useful distinction: NOT every
  # cluster addon needs an IAM role — only ones that call AWS APIs do.
}
