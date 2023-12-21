locals {
  # infra_rg_name                 = "aks-poc"
  # infra_nodes_rg_name           = "aks-poc-nodes"
  # infra_kubernetes_cluster_name = "dev-aks-poc-cluster"
  env                 = "dev"
  resource_group_name = "aks-poc"
  aks_name            = "aks-poc-cluster"
}

data "azurerm_kubernetes_cluster" "this" {
  name                = "${local.env}-${local.aks_name}"
  resource_group_name = local.resource_group_name

  # Comment this out if you get: Error: Kubernetes cluster unreachable 
  # depends_on = [azurerm_kubernetes_cluster.this]
}

provider "helm" {
  kubernetes {
    host                   = data.azurerm_kubernetes_cluster.this.kube_config.0.host
    client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config.0.client_certificate)
    client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config.0.cluster_ca_certificate)
  }
}

# External nginx
resource "helm_release" "external_nginx" {
  name = "external"

  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress"
  create_namespace = true
  version          = "4.8.0"

  values = [file("${path.module}/values/ingress.yaml")]
}

provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config.0.host
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.this.kube_config.0.client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.this.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config.0.cluster_ca_certificate)
}

# add special labels and annotations so git-ops tool will not try to remove it
# after! Terraform will initially create the GitOps
# tool, which will subsequently be managed and modified by GitOps itself!
locals {
  argocd_resources_labels = {
    "app.kubernetes.io/instance"  = "argocd"
    "argocd.argoproj.io/instance" = "argocd"
  }

  argocd_resources_annotations = {
    "argocd.argoproj.io/compare-options" = "IgnoreExtraneous"
    "argocd.argoproj.io/sync-options"    = "Prune=false,Delete=false"
  }
}

# Declare some resources, and the git-ops tool:
resource "kubernetes_namespace" "argocd" {
  depends_on = [data.azurerm_kubernetes_cluster.this]

  metadata {
    name = "argocd"
  }
}

# Auth to fetch git-ops code
resource "kubernetes_secret" "argocd_repo_credentials" {
  depends_on = [kubernetes_namespace.argocd]
  metadata {
    name      = "argocd-repo-credentials"
    namespace = "argocd"
    labels = merge(local.argocd_resources_labels, {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    })
    annotations = local.argocd_resources_annotations
  }
  type = "Opaque"
  data = {
    url           = "git@github.com:aminrj/azure-aks-gitops.git"
    sshPrivateKey = file("./files/githubSSHPrivateKey.key") # TODO: change this to your own private key
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.51.6"
  skip_crds  = true
  depends_on = [
    kubernetes_secret.argocd_repo_credentials,
  ]
  values = [
    file("./files/argocd-bootstrap-values.yaml"),
  ]
}

# The bootstrap application
resource "kubectl_manifest" "argocd_bootstrap" {
  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "bootstrap-${local.aks_name}"
      namespace = "argocd"
    }

    spec = {
      project = "default"
      destination = {
        namespace = "argocd"
        name      = "in-cluster"
      }
      source = {
        repoURL = "git@github.com:aminrj/azure-aks-gitops.git"
        path : "apps"
        revision : "HEAD"
      }
    }
  })
}


# # Deploy nginx-ingress controller with Static IP
# resource "azurerm_public_ip" "nginx_controller" {
#   resource_group_name = data.azurerm_kubernetes_cluster.main.node_resource_group
#   location            = data.azurerm_kubernetes_cluster.main.location

#   name              = "nginx-controller"
#   allocation_method = "Static"
# }

# module "nginx-controller" {
#   source  = "terraform-iaac/nginx-controller/helm"

#   ip_address = azurerm_public_ip.nginx_controller.ip_address
# }
