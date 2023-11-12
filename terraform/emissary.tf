
resource "kubernetes_namespace" "emissary" {
  metadata {
    name = "emissary"
    annotations = {
      "linkerd.io/inject" = "enabled"
    }
  }
}

## IMPORTANT!!! APPLY THIS MANIFEST BEFORE APPLYING THE HELM RELEASE
## https://www.getambassador.io/docs/emissary/latest/tutorials/getting-started
## kubectl apply -f https://app.getambassador.io/yaml/emissary/3.7.2/emissary-crds.yaml

resource "helm_release" "emissary_ingress" {
  name       = "emissary-ingress"
  repository = "https://app.getambassador.io"
  chart      = "emissary-ingress"
  namespace  = kubernetes_namespace.emissary.metadata[0].name
  version    = "8.8.2"

  values = [yamlencode({
    daemonSet   = true
    hostNetwork = true
    dnsPolicy   = "ClusterFirstWithHostNet"
    security = {
      podSecurityContext = null
    }
    module = {
      envoy_log_type = "json"
    }
    service = {
      type = "NodePort"
      annotations = {
        "external-dns.alpha.kubernetes.io/hostname" = "lb.${var.domain}"
      }
      ports = [
        {
          name       = "http"
          port       = 80
          targetPort = 80
        },
        {
          name       = "https"
          port       = 443
          targetPort = 443
        }
      ]
    }
  })]

  depends_on = [helm_release.linkerd]
}

resource "kubernetes_manifest" "http_listener" {
  manifest = {
    apiVersion = "getambassador.io/v3alpha1"
    kind       = "Listener"
    metadata = {
      name      = "http"
      namespace = kubernetes_namespace.emissary.metadata[0].name
    }
    spec = {
      port          = 80
      protocolStack = ["HTTP", "TCP"]
      securityModel = "INSECURE"
      hostBinding = {
        namespace = { from = "ALL" }
      }
    }
  }

  depends_on = [helm_release.emissary_ingress]
}

resource "kubernetes_manifest" "https_listener" {
  manifest = {
    apiVersion = "getambassador.io/v3alpha1"
    kind       = "Listener"
    metadata = {
      name      = "https"
      namespace = kubernetes_namespace.emissary.metadata[0].name
    }
    spec = {
      port          = 443
      protocolStack = ["TLS", "HTTP", "TCP"]
      securityModel = "SECURE"
      hostBinding = {
        namespace = { from = "ALL" }
      }
    }
  }

  depends_on = [helm_release.emissary_ingress]
}
