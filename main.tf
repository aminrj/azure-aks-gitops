locals {
  infra_rg_name                 = "aks-poc"
  infra_nodes_rg_name           = "aks-poc-nodes"
  infra_kubernetes_cluster_name = "aks-poc-lb"
}

provider "azurerm" {
  features {}
}

terraform {
  required_version = ">= 0.13"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
  }
}

data "azurerm_kubernetes_cluster" "main" {
  name                = var.kubernetes_cluster_name
  resource_group_name = local.infra_rg_name
}

provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.main.kube_admin_config.0.host
  username               = data.azurerm_kubernetes_cluster.main.kube_admin_config.0.username
  password               = data.azurerm_kubernetes_cluster.main.kube_admin_config.0.password
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.main.kube_admin_config.0.client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.main.kube_admin_config.0.client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.main.kube_admin_config.0.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
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
  depends_on = [data.azurerm_kubernetes_cluster.main]

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
    url           = "git@github.com:ORG"
    sshPrivateKey = file("./files/githubSSHPrivateKey.key")
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.46.7"
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
      name      = "bootstrap-${var.kubernetes_cluster_name}"
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
        path: "apps"
        revision: "HEAD"
      }
    }
  })

}