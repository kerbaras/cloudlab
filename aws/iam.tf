# IRSA-at-home (decision #17): the cluster's SA issuer is a trusted OIDC
# provider; workloads assume these roles with projected pod tokens. No IAM
# users, no static keys. Roles via the community IRSA module — cert-manager
# and external-dns use its canonical upstream policies.
resource "aws_iam_openid_connect_provider" "cluster" {
  url             = "https://oidc.cloudlab.kerbaras.com"
  client_id_list  = ["sts.amazonaws.com"]
  # computed by AWS at creation (Let's Encrypt chain); kept to avoid drift
  thumbprint_list = ["ab9d0263244dd0326eb67015705a667e79cfe998"]

  tags = {
    project = "cloudlab"
  }
}

module "irsa_cert_manager" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.59"

  role_name                     = "cloudlab-cert-manager"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${aws_route53_zone.kerbaras.zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.cluster.arn
      namespace_service_accounts = ["cert-manager:cert-manager-cert-manager"]
    }
  }

  tags = { project = "cloudlab" }
}

module "irsa_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.59"

  role_name                     = "cloudlab-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/${aws_route53_zone.kerbaras.zone_id}"]

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.cluster.arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = { project = "cloudlab" }
}

module "irsa_flux_sops" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.59"

  role_name = "cloudlab-flux-sops"

  role_policy_arns = {
    sops = aws_iam_policy.flux_sops_kms.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.cluster.arn
      namespace_service_accounts = ["flux-system:kustomize-controller"]
    }
  }

  tags = { project = "cloudlab" }
}

resource "aws_iam_policy" "flux_sops_kms" {
  name        = "cloudlab-flux-sops-kms"
  description = "Decrypt sops-encrypted Git secrets with the cloudlab KMS key"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.sops.arn
      },
    ]
  })

  tags = { project = "cloudlab" }
}
