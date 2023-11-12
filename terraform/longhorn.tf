resource "kubernetes_namespace" "longhorn" {
  metadata {
    name = "longhorn"
  }
}

resource "helm_release" "longhorn" {
  name       = "longhorn"
  repository = "https://charts.longhorn.io"
  chart      = "longhorn"
  namespace  = kubernetes_namespace.longhorn.metadata[0].name
}
