# Terraform owns exactly one object: the ArgoCD Application in the argocd
# namespace. It does NOT manage the Deployment, Service, ConfigMap or PDB -
# ArgoCD still does that, straight from kustomization.yaml at the repo root.
#
# That split is deliberate. The Application has `selfHeal: true`, so anything
# that edits the workload behind ArgoCD's back gets reverted within ~3
# minutes. By moving only the image tag - through the Application's kustomize
# image override - Terraform asks ArgoCD to roll the new version out instead
# of fighting it for ownership of the Deployment.
terraform {
  required_version = ">= 1.6"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }

  # State lives in a Secret in the cluster, so there is no bucket to provision
  # and CI reaches it with the same kubeconfig it already needs for the apply.
  # The namespace is NOT created by this backend - see `make tf-init` and the
  # deploy workflow, both of which ensure it first.
  #
  # `config_path` is intentionally not set here: it differs between a laptop
  # and CI, so it is passed at init time with
  #   terraform init -backend-config="config_path=/path/to/kubeconfig"
  backend "kubernetes" {
    secret_suffix = "billing-getway"
    namespace     = "terraform-state"
  }
}
