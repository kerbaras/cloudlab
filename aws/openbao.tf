# OpenBao's auto-unseal key: a dedicated KMS key (never the sops key — losing
# one must not lose both) plus an IRSA role so the unseal is keyless like
# everything else.
resource "aws_kms_key" "openbao_unseal" {
  description = "cloudlab OpenBao auto-unseal"

  tags = {
    project = "cloudlab"
  }

  lifecycle {
    # losing this key = OpenBao can never unseal again (recovery keys aside)
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "openbao_unseal" {
  name          = "alias/cloudlab-openbao-unseal"
  target_key_id = aws_kms_key.openbao_unseal.key_id
}

module "irsa_openbao" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.59"

  role_name = "cloudlab-openbao"

  role_policy_arns = {
    unseal = aws_iam_policy.openbao_unseal.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.cluster.arn
      namespace_service_accounts = ["openbao:openbao"]
    }
  }

  tags = { project = "cloudlab" }
}

resource "aws_iam_policy" "openbao_unseal" {
  name        = "cloudlab-openbao-unseal"
  description = "OpenBao awskms seal operations on its unseal key"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.openbao_unseal.arn
      },
    ]
  })

  tags = { project = "cloudlab" }
}
