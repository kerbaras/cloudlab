resource "kubernetes_namespace" "linkerd" {
  metadata {
    name = "linkerd"
  }
}

resource "helm_release" "linkerd_crds" {
  name       = "linkerd-crds"
  namespace  = kubernetes_namespace.linkerd.metadata[0].name
  repository = "https://helm.linkerd.io/stable"
  chart      = "linkerd-crds"
}

resource "helm_release" "linkerd" {
  name       = "linkerd"
  namespace  = kubernetes_namespace.linkerd.metadata[0].name
  repository = "https://helm.linkerd.io/stable"
  chart      = "linkerd-control-plane"

  set_sensitive {
    name  = "identityTrustAnchorsPEM"
    value = tls_self_signed_cert.linkerd_ca.cert_pem
  }

  set {
    name  = "identity.issuer.scheme"
    value = "kubernetes.io/tls"
  }

  values = [yamlencode({
    enablePodAntiAffinity     = false
    enablePodDisruptionBudget = false
    highAvailability          = false
    controllerReplicas        = 1
    proxy = {
      resources = {
        cpu    = { request = "10m" }
        memory = { request = "20Mi" }
      }
    }
  })]

  depends_on = [helm_release.linkerd_crds, kubernetes_manifest.linkerd_identity_cert]
}


# CA Certificate
resource "tls_private_key" "linkerd_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "linkerd_ca" {

  private_key_pem = tls_private_key.linkerd_ca.private_key_pem

  is_ca_certificate = true

  validity_period_hours = 87600 # 10 years
  early_renewal_hours   = 2160  # 90 days

  subject {
    common_name = "root.linkerd.cluster.local"
  }

  allowed_uses = [
    "crl_signing",
    "cert_signing",
    "server_auth",
    "client_auth"
  ]
}

resource "kubernetes_secret" "linkerd_trust_anchor" {

  metadata {
    name      = "linkerd-trust-anchor"
    namespace = kubernetes_namespace.linkerd.metadata[0].name
  }

  data = {
    "tls.crt" = tls_self_signed_cert.linkerd_ca.cert_pem
    "tls.key" = tls_private_key.linkerd_ca.private_key_pem
  }

  type = "kubernetes.io/tls"
}

resource "kubernetes_manifest" "linkerd_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "linkerd-trust-anchor"
      namespace = kubernetes_namespace.linkerd.metadata[0].name
    }
    spec = {
      ca = {
        secretName = kubernetes_secret.linkerd_trust_anchor.metadata[0].name
      }
    }
  }
}

# Identity Certificate
resource "kubernetes_manifest" "linkerd_identity_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "linkerd-identity-issuer"
      namespace = kubernetes_namespace.linkerd.metadata[0].name
    }
    spec = {
      commonName  = "identity.linkerd.cluster.local"
      secretName  = "linkerd-identity-issuer"
      isCA        = true
      dnsNames    = ["identity.linkerd.cluster.local"]
      duration    = "8760h0m0s" # 365 days
      renewBefore = "2160h0m0s" # 90 days
      issuerRef = {
        name = "linkerd-trust-anchor"
        kind = "Issuer"
      }
      privateKey = {
        algorithm = "ECDSA"
      }
      usages = [
        "cert sign",
        "crl sign",
        "server auth",
        "client auth"
      ]
    }
  }

  depends_on = [kubernetes_manifest.linkerd_issuer]
}
