# Terraform owns exactly one object per environment: the ArgoCD Application in
# that cluster's argocd namespace. It does NOT manage the Deployment, Service,
# ConfigMap or PDB - ArgoCD still does that, straight from kustomization.yaml
# at the repo root.
#
# That split is deliberate. The Application has `selfHeal: true`, so anything
# that edits the workload behind ArgoCD's back gets reverted within ~3
# minutes. By moving only the image tag and replica count - through the
# Application's kustomize overrides - Terraform asks ArgoCD to roll the new
# version out instead of fighting it for ownership of the Deployment.
terraform {
  # >= 1.9 for cross-variable `validation` blocks: image_tag's channel prefix
  # is checked against `environment`, which needs one variable to reference
  # another.
  required_version = ">= 1.9"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }

  # One state per environment, each living in its own cluster - dev state in
  # the dev cluster, prod state in the prod cluster - so there is no bucket to
  # provision and CI reaches the state with the same kubeconfig it already
  # needs for the apply. The namespace is NOT created by this backend; `make
  # tf-init` and the deploy workflow both ensure it first.
  #
  # Neither `config_path` nor `secret_suffix` is set here, on purpose:
  #
  #   config_path    differs between a laptop and CI
  #   secret_suffix  is what separates dev/stg/prod state
  #
  # Both are passed at init time, and `make tf-init ENV=<env>` is the only
  # thing that should be assembling them:
  #
  #   terraform init \
  #     -backend-config="config_path=/path/to/kubeconfig" \
  #     -backend-config="secret_suffix=billing-getway-prod"
  #
  # Running a bare `terraform init` leaves secret_suffix unset and Terraform
  # will prompt for it rather than quietly sharing one state between
  # environments.
  backend "kubernetes" {
    namespace = "terraform-state"
  }
}
