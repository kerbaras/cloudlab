# cloudlab

Infrastructure repository for my [cloud-lab](https://home.kerbaras.com)

## Overview

Infrastructure as Code for my cloud-based lab. This repository contains provisioning and configuration definitions in Terraform and Kustomization for a Kubernetes Cluster Environment.

> [!IMPORTANT]
> This project is still in the experimental stage and it's used to run experiments and learn new technologies. It's not intended to be used in production environments.
> For more information check [the roadmap](#roadmap).

## Technology Stack

| Logo                                                                                                        | Name                                              | Description                         |
| ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | ----------------------------------- |
| <img width="32" src="https://cdn.jsdelivr.net/gh/devicons/devicon/icons/terraform/terraform-original.svg"/> | [Terraform](https://www.terraform.io/)            | Infrastructure as Code              |
| <img width="32" src="https://cdn.jsdelivr.net/gh/devicons/devicon/icons/kubernetes/kubernetes-plain.svg"/>  | [Kubernetes](https://kubernetes.io/)              | Container Orchestration             |
| <img width="32" src="https://img.stackshare.io/service/12670/kustomize.png"/>                               | [Kustomize](https://kustomize.io/)                | Kubernetes Configuration Management |
| <img width="32" src="https://avatars.githubusercontent.com/u/15859888?s=200&v=4"/>                          | [Helm](https://helm.sh/)                          | Kubernetes Package Manager          |
| <img width="32" src="https://avatars.githubusercontent.com/u/30269780?s=200&v=4"/>                          | [ArgoCD](https://argoproj.github.io/argo-cd/)     | GitOps Continuous Delivery          |
| <img width="32" src="https://github.com/jetstack/cert-manager/raw/master/logo/logo.png"/>                   | [Cert-Manager](https://cert-manager.io/)          | Kubernetes Certificate Management   |
| <img width="32" src="https://k0sproject.io/images/k0s-logo.svg"/>                                           | [k0s](https://k0sproject.io/)                     | Kubernetes Distribution             |
| <img width="32" src="https://longhorn.io/img/logos/longhorn-icon-white.png"/>                               | [Longhorn](https://longhorn.io/)                  | Kubernetes Storage Orchestration    |
| <img width="32" src="https://avatars.githubusercontent.com/u/60239468?s=200&v=4"/>                          | [MetalLB](https://metallb.universe.tf/)           | Kubernetes Load Balancer            |
| <img width="32" src="https://avatars.githubusercontent.com/u/79531940?s=200&v=4"/>                          | [Emissary Ingress](https://www.getambassador.io/) | Kubernetes API Gateway              |
| <img width="32" src="https://avatars.githubusercontent.com/u/25301026?s=200&v=4"/>                          | [Linkerd](https://linkerd.io/)                    | Kubernetes Service Mesh             |
| <img width="32" src="https://avatars.githubusercontent.com/u/3380462?s=200&v=4"/>                           | [Prometheus](https://prometheus.io/)              | Kubernetes Monitoring               |
| <img width="32" src="https://avatars.githubusercontent.com/u/7195757?s=200&v=4"/>                           | [Grafana](https://grafana.com/)                   | Kubernetes Observability            |
| <img width="32" src="https://github.com/grafana/loki/raw/main/docs/sources/logo.png?raw=true"/>             | [Loki](https://grafana.com/oss/loki/)             | Kubernetes Log Aggregation          |
| <img width="32" src="https://raw.githubusercontent.com//bastienwirtz/homer/main/public/logo.png"/>          | [Homer](https://github.com/bastienwirtz/homer)    | Kubernetes Dashboard                |
| <img width="32" src="https://avatars.githubusercontent.com/u/22225832?s=200&v=4"/>                          | [Portainer](https://www.portainer.io/)            | Kubernetes Dashboard                |

### Hardware

So far the lab is running on [Hertzner](https://www.hetzner.com/) with the following nodes:

- AX41-NVMe:
  - CPU: AMD Ryzen 5 3600 6-Core
  - RAM: 64 GB DDR4
  - Storage: 2 x 512 GB NVMe SSD

### Features

- [x] Kubernetes Cluster: Using [k0s](https://k0sproject.io/) as Kubernetes distribution
- [x] GitOps Continuous Delivery: Using [ArgoCD](https://argoproj.github.io/argo-cd/) as GitOps Continuous Delivery
- [x] Application Dashboard: Using [Homer](https://github.com/bastienwirtz/homer)
- [x] Kubernetes Dashboard: Using [Portainer](https://www.portainer.io/)
- [x] Single Sign-On: Using [Zitadel](https://zitadel.com/)
  - [ ] Kubernetes OIDC Authentication
  - [ ] Private Application Authentication
  - [ ] Private Docker Registry Authentication
- [x] Kubernetes Storage Orchestration: Using [Longhorn](https://longhorn.io/)
- [ ] Monitoring and Alerting
- [ ] Virtual Private Network
- [ ] NAT Load Balancer
- [ ] Virtual Private Cloud
- [ ] Virtual Machine Orchestration

## Getting Started

So far this is not supported out of the box. Provisioning is handled by Terraform, but some resources need to be created manually.

### Bootstrap the Cluster

```bash
cd k0s
k0sctl apply -c k0sctl.yaml
```

### Provisioning Infrastructure

```bash
cd terraform
terraform init
terraform apply --var-file=cloudlab.tfvars
```

### Deploying Applications

Applications are handled by ArgoCD. To deploy an application, create a new folder under `apps/{my-app}` and add a `kustomization.yaml` file.
Then add the application to the `applications.tf` file and deploy it using terraform.

The app folder follows the following structure:

```
apps
└── my-app
    ├── base
    │   ├── kustomization.yaml
    │   └── deplyment.yaml
    └── overlays
        ├── dev
        │   ├── kustomization.yaml
        │   └── app.env
        └── prod
            ├── kustomization.yaml
            └── app.yaml
```
