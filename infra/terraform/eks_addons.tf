# ---------------------------------------------------------------------------
# Add-ons y controllers que se instalan SOBRE el cluster EKS (eks.tf).
#
# Dos categorias:
#   1. EKS managed add-ons (aws_eks_addon): componentes core del plano de
#      datos (vpc-cni, coredns, kube-proxy) con version gestionada por AWS.
#   2. Controllers via Helm, cada uno con su rol IRSA de minimo privilegio:
#        - AWS Load Balancer Controller -> crea el ALB desde el Ingress (Opcion A)
#        - Cluster Autoscaler           -> escala el node group (nodos)
#        - metrics-server               -> metricas de CPU/mem para el HPA
#        - ExternalDNS                  -> registro Route53 del ALB
#        - Secrets Store CSI + provider -> monta secretos de Secrets Manager
#
# NOTA (challenge): no se despliega. Las versiones de chart son placeholders
# razonables; en real se fijan y se prueban en staging antes de produccion.
# ---------------------------------------------------------------------------

locals {
  oidc_provider_url = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

# Helper para construir el assume-role policy de IRSA de un ServiceAccount dado.
# (Se repite el patron en cada rol porque Terraform no permite funciones.)

# =========================================================================
# 1. EKS managed add-ons
# =========================================================================
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "vpc-cni"
  addon_version = var.eks_addon_versions["vpc-cni"]

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "coredns"
  addon_version = var.eks_addon_versions["coredns"]

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.api]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "kube-proxy"
  addon_version = var.eks_addon_versions["kube-proxy"]

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# =========================================================================
# 2a. AWS Load Balancer Controller (dueño del ALB en Opcion A)
# =========================================================================
data "aws_iam_policy_document" "lbc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.project_name}-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
}

# Politica oficial del controller (resumida a las acciones que necesita para
# gestionar ALBs/target groups/listeners/WAF/SG). En real se usa el JSON
# completo publicado por el proyecto.
resource "aws_iam_role_policy" "lbc" {
  name = "${var.project_name}-lbc-policy"
  role = aws_iam_role.lbc.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:*",
        "ec2:Describe*",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateSecurityGroup",
        "ec2:CreateTags",
        "wafv2:AssociateWebACL",
        "wafv2:DisassociateWebACL",
        "wafv2:GetWebACLForResource",
        "acm:ListCertificates",
        "acm:DescribeCertificate",
        "iam:CreateServiceLinkedRole",
        "cognito-idp:DescribeUserPoolClient",
        "shield:GetSubscriptionState"
      ]
      Resource = "*"
    }]
  })
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.helm_chart_versions["aws-load-balancer-controller"]
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.main.name
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
    value = aws_iam_role.lbc.arn
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = aws_vpc.main.id
  }

  depends_on = [aws_eks_node_group.api, aws_iam_role_policy.lbc]
}

# =========================================================================
# 2b. Cluster Autoscaler (escala nodos del node group)
# =========================================================================
data "aws_iam_policy_document" "autoscaler_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }
  }
}

resource "aws_iam_role" "autoscaler" {
  name               = "${var.project_name}-autoscaler-role"
  assume_role_policy = data.aws_iam_policy_document.autoscaler_assume.json
}

resource "aws_iam_role_policy" "autoscaler" {
  name = "${var.project_name}-autoscaler-policy"
  role = aws_iam_role.autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeLaunchTemplateVersions"
      ]
      Resource = "*"
    }]
  })
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.helm_chart_versions["cluster-autoscaler"]
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = aws_eks_cluster.main.name
  }
  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.autoscaler.arn
  }

  depends_on = [aws_eks_node_group.api, aws_iam_role_policy.autoscaler]
}

# =========================================================================
# 2c. metrics-server (HPA por CPU/memoria)
# =========================================================================
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.helm_chart_versions["metrics-server"]
  namespace  = "kube-system"

  depends_on = [aws_eks_node_group.api]
}

# =========================================================================
# 2d. ExternalDNS (registro Route53 del ALB -> var.domain_name)
# =========================================================================
data "aws_iam_policy_document" "externaldns_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }
  }
}

resource "aws_iam_role" "externaldns" {
  name               = "${var.project_name}-externaldns-role"
  assume_role_policy = data.aws_iam_policy_document.externaldns_assume.json
}

resource "aws_iam_role_policy" "externaldns" {
  name = "${var.project_name}-externaldns-policy"
  role = aws_iam_role.externaldns.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = [aws_route53_zone.main.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
        Resource = ["*"]
      }
    ]
  })
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = var.helm_chart_versions["external-dns"]
  namespace  = "kube-system"

  set {
    name  = "provider"
    value = "aws"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.externaldns.arn
  }
  set {
    name  = "txtOwnerId"
    value = aws_route53_zone.main.zone_id
  }

  depends_on = [aws_eks_node_group.api, aws_iam_role_policy.externaldns]
}

# =========================================================================
# 2e. Secrets Store CSI Driver + AWS provider (monta secretos de Secrets Manager)
# =========================================================================
resource "helm_release" "secrets_store_csi_driver" {
  name       = "secrets-store-csi-driver"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = var.helm_chart_versions["secrets-store-csi-driver"]
  namespace  = "kube-system"

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }

  depends_on = [aws_eks_node_group.api]
}

resource "helm_release" "secrets_store_csi_aws_provider" {
  name       = "secrets-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = var.helm_chart_versions["secrets-store-csi-driver-provider-aws"]
  namespace  = "kube-system"

  depends_on = [helm_release.secrets_store_csi_driver]
}
