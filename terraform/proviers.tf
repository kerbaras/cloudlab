terraform {
  backend "local" {
    path = ".terraform/.tfstate"
  }

  required_providers {
    # zitadel = {
    #   source  = "zitadel/zitadel"
    #   version = "1.0.4"
    # }
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "dedicated"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "dedicated"
  }
}

# provider "zitadel" {
#   domain           = local.accounts_domain
#   insecure         = false
#   port             = 443
#   jwt_profile_file = "private_key_jwt.json"
# }
