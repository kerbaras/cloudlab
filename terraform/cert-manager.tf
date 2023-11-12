resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.13.1"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }

  values = [yamlencode({
    webhook = {
      enabled = true
    }
  })]
}


resource "kubernetes_manifest" "cluster_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.domain
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.contact
        privateKeySecretRef = {
          name = "kerbaras-com-issuer"
        }
        solvers = [
          {
            dns01 = {
              route53 = {
                region       = "us-east-1"
                hostedZoneID = var.hosted_zone_id
                accessKeyIDSecretRef = {
                  name = "aws-access"
                  key  = "AWS_ACCESS_KEY_ID"
                }
                secretAccessKeySecretRef = {
                  name = "aws-access"
                  key  = "AWS_SECRET_ACCESS_KEY"
                }
              }
              selector = {
                dnsZones = [var.domain]
              }
            }
          }
        ]
      }
    }
  }
  depends_on = [helm_release.cert_manager]
}

