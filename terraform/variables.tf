# ---------------------------------------------------------------------------
# Cluster access
# ---------------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the cluster ArgoCD runs in."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to use. null means whatever is current."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# What is being deployed
# ---------------------------------------------------------------------------

variable "image_repository" {
  description = "Docker repository the gateway image is published to."
  type        = string
  default     = "autofikbyslaap/dev.api.billing.getway"
}

variable "image_tag" {
  description = <<-DESC
    The immutable image tag to roll out, as the app repo's master.yml
    publishes it: `dev-<version>`, `stg-<version>` or `prod-<version>`
    (note: no `v` - the tag `dev-v1.2.3` builds the image `dev-1.2.3`).
  DESC
  type        = string

  # The whole point of a release-triggered deploy is that the git history
  # records what is running. `master`, `testing` and `production` are moving
  # tags that master.yml re-points on every release: applying one of them
  # changes nothing in the Application spec, so ArgoCD sees no diff and
  # deploys nothing, and a week later there is no way to tell what shipped.
  validation {
    condition     = !contains(["master", "testing", "production", "latest"], var.image_tag)
    error_message = "image_tag must be an immutable tag such as dev-1.2.3, not a moving channel tag (master/testing/production/latest). A moving tag produces no diff, so ArgoCD would deploy nothing. To re-pull a moving tag, use `make restart` instead."
  }

  validation {
    condition     = can(regex("^(dev|stg|prod)-[0-9]+\\.[0-9]+\\.[0-9]+$", var.image_tag))
    error_message = "image_tag must look like dev-1.2.3, stg-1.2.3 or prod-1.2.3 - the format master.yml publishes."
  }
}

# ---------------------------------------------------------------------------
# The ArgoCD Application itself
#
# These default to exactly what argocd-application.yaml declares, so a plain
# `terraform apply` reproduces that file plus the image override. Keep the two
# in sync, or let Terraform be the source of truth - see README.md.
# ---------------------------------------------------------------------------

variable "app_name" {
  description = "Name of the ArgoCD Application."
  type        = string
  default     = "billing-getway-internal"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD runs in."
  type        = string
  default     = "argocd"
}

variable "argocd_project" {
  description = "ArgoCD project the Application belongs to."
  type        = string
  default     = "default"
}

variable "repo_url" {
  description = "Git repository ArgoCD syncs the manifests from."
  type        = string
  default     = "https://github.com/openLabDnx/autofik.api.dev.getway.internal.billing.git"
}

variable "target_revision" {
  description = "Branch or tag of repo_url to sync."
  type        = string
  default     = "master"
}

variable "source_path" {
  description = "Path within repo_url holding kustomization.yaml."
  type        = string
  default     = "."
}

variable "dest_server" {
  description = "Cluster the workload is deployed to. The in-cluster default is the cluster ArgoCD itself runs in."
  type        = string
  default     = "https://kubernetes.default.svc"
}

variable "dest_namespace" {
  description = "Namespace the workload is deployed into. Must match the `namespace:` hardcoded in billing-getway.yml."
  type        = string
  default     = "billing-gateway"
}
