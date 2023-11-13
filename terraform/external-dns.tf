resource "kubernetes_namespace" "external_dns" {

  metadata {
    name = "external-dns"
  }
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "external-dns"
  namespace  = kubernetes_namespace.external_dns.metadata[0].name
  version    = "6.26.5"

  set {
    name  = "provider"
    value = "aws"
  }

  set {
    name  = "crd.create"
    value = true
  }

  values = [yamlencode({
    txtPrefix                 = "_external-dns."
    sources                   = ["crd", "service", "ingress", "ambassador-host"]
    managedRecordTypesFilters = ["A", "AAAA", "CNAME", "SRV", "TXT"]
    aws = {
      region   = "us-east-1"
      zoneType = "public"
      credentials = {
        accessKeyIDSecretRef = {
          name = "aws-access"
          key  = "AWS_ACCESS_KEY_ID"
        }
        secretAccessKeySecretRef = {
          name = "aws-access"
          key  = "AWS_SECRET_ACCESS_KEY"
        }
      }
    }
  })]

  depends_on = [helm_release.emissary_ingress]
}


# emissary integration
resource "kubernetes_cluster_role" "emissary_externaldns" {
  metadata {
    name = "emissary-externaldns"
  }

  rule {
    api_groups = ["getambassador.io"]
    resources  = ["hosts"]
    verbs      = ["get", "list", "watch"]
  }

  depends_on = [helm_release.emissary_ingress, helm_release.external_dns]
}

resource "kubernetes_cluster_role_binding" "emissary_externaldns" {
  metadata {
    name = "emissary-externaldns"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.emissary_externaldns.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "external-dns"
    namespace = "external-dns"
  }

  depends_on = [helm_release.emissary_ingress, helm_release.external_dns]
}
