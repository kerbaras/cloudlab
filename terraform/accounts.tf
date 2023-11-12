## This file contains all the necessary resources for the SSO account endpoint of the lab

# Create a namespace for the SSO account endpoint
resource "kubernetes_namespace" "accounts" {
  metadata {
    name = "accounts"
  }
}

# deploy crdb
resource "helm_release" "zitadel_crdb" {
  name       = "crdb"
  repository = "https://charts.cockroachdb.com/"
  chart      = "cockroachdb"
  namespace  = kubernetes_namespace.accounts.metadata[0].name

  set {
    name  = "tls.enabled"
    value = "true"
  }

  values = [yamlencode({
    fullnameOverride = "crdb",
    conf = {
      "single-node" = true
    }
    statefulset = {
      replicas = 1
      annotations = {
        "linkerd.io/inject" = "enabled"
      }
    }
  })]
}

locals {
  accounts_domain = "accounts.${var.domain}"
}

variable "accounts_admin" {
  type        = any
  description = "(optional) initial admin user for the accounts endpoint"
}

variable "zitadel_crdb_password" {
  sensitive   = true
  type        = string
  description = "password for the crdb user"
}

resource "helm_release" "zitadel" {
  name       = "zitadel"
  repository = "https://charts.zitadel.com"
  chart      = "zitadel"
  namespace  = kubernetes_namespace.accounts.metadata[0].name

  values = [yamlencode({
    replicaCount = 1
    podAnnotations = {
      "linkerd.io/inject" = "enabled"
    }
    zitadel = {
      masterkeySecretName = "zitadel-master-key"
      configmapConfig = {
        ExternalSecure = true
        ExternalDomain = local.accounts_domain
        ExternalPort   = 443
        FirstInstance = {
          Org = {
            Name  = var.domain
            Human = var.accounts_admin
          }
        }
        TLS = {
          Enabled = false
        }
        Database = {
          Cockroach = {
            Host = "crdb-public"
            User = {
              SSL = {
                Mode = "verify-full"
              }
            }
            Admin = {
              SSL = {
                Mode = "verify-full"
              }
            }
          }
        }
      }
      secretConfig = {
        Database = {
          Cockroach = {
            User = {
              Password = var.zitadel_crdb_password
            }
          }
        }
      }
      dbSslCaCrtSecret    = "crdb-ca-secret"
      dbSslAdminCrtSecret = "crdb-client-secret"
    }
  })]

  depends_on = [helm_release.zitadel_crdb]
}

resource "kubernetes_manifest" "accounts_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "accounts"
      namespace = kubernetes_namespace.accounts.metadata[0].name
    }
    spec = {
      secretName = "accounts-cert"
      dnsNames = [
        local.accounts_domain
      ]
      issuerRef = {
        name = var.domain
        kind = "ClusterIssuer"
      }
    }
  }
}
resource "kubernetes_manifest" "accounts_host" {
  manifest = {
    apiVersion = "getambassador.io/v3alpha1"
    kind       = "Host"
    metadata = {
      name      = "accounts"
      namespace = kubernetes_namespace.accounts.metadata[0].name
      annotations = {
        "external-dns.ambassador-service" = "emissary-ingress.emissary"
      }
    }
    spec = {
      hostname = local.accounts_domain
      tlsSecret = {
        name = "accounts-cert"
      }
    }
  }
}

resource "kubernetes_manifest" "accounts_mapping" {
  manifest = {
    apiVersion = "getambassador.io/v3alpha1"
    kind       = "Mapping"
    metadata = {
      name      = "accounts"
      namespace = kubernetes_namespace.accounts.metadata[0].name
    }
    spec = {
      prefix   = "/"
      hostname = local.accounts_domain
      service  = "zitadel:8080"
    }
  }
}


