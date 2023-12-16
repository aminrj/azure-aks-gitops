# GitOps Project for AKS Cluster

This project is designed to configure and deploy the GitOps tool on an existing Azure Kubernetes Service (AKS) cluster using Terraform.

## Prerequisites

- An existing AKS cluster
- Terraform installed
- Azure CLI installed and configured

## Getting Started

1. Clone this repository to your local machine.

```bash
git clone <repository-url>
```
2. `terraform init`
3. `terraform plan`
4. `terraform apply`
5. Port-forward for dev/test:
    `kubectl port-forward -n argocd svc/argocd-server 8080:80`
6. Get the credentials for `admin` user :
   ```bash
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   ```