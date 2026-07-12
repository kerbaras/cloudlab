# SOPS master key (decision #15). Encrypters: operator credentials.
# Decrypter: the cloudlab-flux-sops role (kms:Decrypt via IRSA, iam.tf).
resource "aws_kms_key" "sops" {
  description = "cloudlab SOPS encryption key (Flux + operator)"

  tags = {
    project = "cloudlab"
  }

  lifecycle {
    # losing this key = losing every sops-encrypted secret in Git
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "sops" {
  name          = "alias/cloudlab-sops"
  target_key_id = aws_kms_key.sops.key_id
}
