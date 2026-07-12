# One-shot adoption of the imperatively-created footprint. Idempotent — kept
# as the record of what was imported and from where.
import {
  to = aws_kms_key.sops
  id = "99cadca6-ba46-4ef0-9df2-9f2678b7962e"
}

import {
  to = aws_kms_alias.sops
  id = "alias/cloudlab-sops"
}

import {
  to = aws_iam_openid_connect_provider.cluster
  id = "arn:aws:iam::203447569320:oidc-provider/oidc.cloudlab.kerbaras.com"
}

# Roles adopt into the module; their creation-era inline policies are NOT
# imported — the module attaches managed equivalents and the inline ones are
# deleted out-of-band after the first apply.
import {
  to = module.irsa_cert_manager.aws_iam_role.this[0]
  id = "cloudlab-cert-manager"
}

import {
  to = module.irsa_external_dns.aws_iam_role.this[0]
  id = "cloudlab-external-dns"
}

import {
  to = module.irsa_flux_sops.aws_iam_role.this[0]
  id = "cloudlab-flux-sops"
}

import {
  to = aws_route53_zone.kerbaras
  id = "Z06703852MPXYIJOZFML8"
}
