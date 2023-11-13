resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    annotations = {
      "linkerd.io/inject" = "enabled"
    }
  }
}

locals {
  argocd_domain = "argocd.${var.domain}"
}

variable "argo_oidc_config" {
  type        = any
  description = "OIDC configuration for argocd"
  default     = null
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = "5.43.4"

  values = [yamlencode({
    configs = {
      cm = {
        url           = "https://${local.argocd_domain}"
        "oidc.config" = var.argo_oidc_config != null ? yamlencode(var.argo_oidc_config) : null
      }
      params = {
        "server.insecure" = true
      }
      rbac = {
        "policy.csv" = "g, admin, role:admin\ng, developer, role:developer\ng, readonly, role:readonly"
      }
    }
    controller = {
      replicas = 1
    }
    server = {
      extraArgs = ["--insecure"]
    }
  })]
}

resource "kubernetes_manifest" "argocd_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.argocd_domain
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      commonName = local.argocd_domain
      secretName = "argocd-certs"
      issuerRef = {
        name = var.domain
        kind = "ClusterIssuer"
      }
      dnsNames = [
        local.argocd_domain
      ]
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "argocd_host" {
  manifest = {
    apiVersion = "getambassador.io/v3alpha1"
    kind       = "Host"
    metadata = {
      name      = "argocd"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      hostname = local.argocd_domain
      tlsSecret = {
        name = "argocd-certs"
      }
    }
  }

  depends_on = [kubernetes_manifest.argocd_cert, helm_release.emissary_ingress]
}

resource "kubernetes_manifest" "argocd_web" {
  manifest = {
    apiVersion = "getambassador.io/v3alpha1"
    kind       = "Mapping"
    metadata = {
      name      = "argocd-ui"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      hostname = local.argocd_domain
      prefix   = "/"
      service  = "argocd-server.argocd:443"
    }
  }

  depends_on = [kubernetes_manifest.argocd_host, helm_release.emissary_ingress]
}

resource "kubernetes_manifest" "argocd_cli" {
  manifest = {
    apiVersion = "getambassador.io/v3alpha1"
    kind       = "Mapping"
    metadata = {
      name      = "argocd-cli"
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      hostname = local.argocd_domain
      prefix   = "/"
      service  = "argocd-server.argocd:80"
      regex_headers = {
        "Content-Type" = "^application/grpc.*$"
      }
      grpc = true
    }
  }

  depends_on = [kubernetes_manifest.argocd_host, helm_release.emissary_ingress]
}

resource "kubernetes_manifest" "argocd_dns" {
  manifest = {
    apiVersion = "externaldns.k8s.io/v1alpha1"
    kind       = "DNSEndpoint"
    metadata = {
      name      = local.argocd_domain
      namespace = kubernetes_namespace.argocd.metadata[0].name
    }
    spec = {
      endpoints = [
        {
          dnsName    = local.argocd_domain
          recordTTL  = 300
          recordType = "A"
          targets = [

          ]
        }
      ]
    }
  }

  depends_on = [helm_release.external_dns]
}
