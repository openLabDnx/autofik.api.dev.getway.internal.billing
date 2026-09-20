# ---------------------------------------------------------------------------
# Which environment this apply targets
#
# dev, stg and prod are three SEPARATE clusters, each running its own ArgoCD.
# So the Application name, the namespace and the ArgoCD namespace are the same
# in all three - what actually differs is the cluster Terraform talks to
# (kubeconfig_path), the release channel it will accept (image_tag) and the
# Secret its state lives in (the backend's secret_suffix, set at init time).
# ---------------------------------------------------------------------------

variable "environment" {
  description = "Target environment: dev, stg or prod. Selects the release channel and, with it, which image tags are allowed."
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of: dev, stg, prod."
  }
}

# ---------------------------------------------------------------------------
# Cluster access
#
# Each environment is its own cluster, so this must point at the cluster whose
# ArgoCD should run the workload. Getting it wrong is the one mistake that
# silently deploys to the wrong place, which is why `make tf-apply` prints the
# context first and asks before touching prod.
# ---------------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the cluster ArgoCD runs in, for this environment."
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
  description = <<-DESC
    Docker repository the gateway image is published to. One repository serves
    all three environments - the tag prefix is what distinguishes them, so the
    legacy `dev.` in the name says nothing about which environment is running
    it. Only the tag does.
  DESC
  type        = string
  default     = "autofikbyslaap/dev.api.billing.getway"
}

variable "image_tag" {
  description = <<-DESC
    The immutable image tag to roll out, as the app repo's master.yml
    publishes it: `dev-<version>`, `stg-<version>` or `prod-<version>`
    (note: no `v` - the git tag `dev-v1.2.3` builds the image `dev-1.2.3`).

    The channel prefix must match `environment`. That is what stops an
    untested dev build reaching production.
  DESC
  type        = string

  # Checked first, because pinning a moving tag is the most common mistake and
  # deserves an error that names the cause rather than just the syntax.
  #
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

  # The cross-check that makes the environment split mean something: a prod
  # apply will only accept a prod- image. Terraform >= 1.9 is what allows a
  # validation block to reference another variable.
  validation {
    condition     = startswith(var.image_tag, "${var.environment}-")
    error_message = "image_tag must carry the ${var.environment} channel prefix (${var.environment}-1.2.3). Promote a build by re-tagging it in the app repo for this channel - do not point one environment at another's image."
  }
}

# ---------------------------------------------------------------------------
# Per-environment sizing
#
# ArgoCD applies this as a kustomize replica override, the same mechanism as
# the image override: billing-getway.yml keeps `replicas: 2` for a plain
# `kubectl apply -k .`, and the Application rewrites it at sync time.
# ---------------------------------------------------------------------------

variable "replicas" {
  description = "Replica count to override the Deployment with. null uses the per-environment default below."
  type        = number
  default     = null

  validation {
    condition     = var.replicas == null ? true : var.replicas >= 1
    error_message = "replicas must be at least 1."
  }
}

variable "environment_defaults" {
  description = "Per-environment sizing. Production runs an extra replica so a node failure still leaves two serving."
  type        = map(object({ replicas = number }))

  default = {
    dev  = { replicas = 2 }
    stg  = { replicas = 2 }
    prod = { replicas = 3 }
  }
}

# ---------------------------------------------------------------------------
# The ArgoCD Application itself
#
# These default to exactly what argocd-application.yaml declares, so a plain
# `terraform apply` reproduces that file plus the image and replica overrides.
# Keep the two in sync, or let Terraform be the source of truth - see README.
# ---------------------------------------------------------------------------

variable "app_name" {
  description = "Name of the ArgoCD Application. The same in every cluster, because the clusters are what separate the environments."
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
  description = <<-DESC
    Branch or tag of repo_url to sync. All three environments track `master`
    today, which means a manifest commit reaches production as soon as it
    lands. Once there is a release branch, point prod at it in
    envs/prod.tfvars rather than changing this default.
  DESC
  type        = string
  default     = "master"
}

variable "source_path" {
  description = "Path within repo_url holding kustomization.yaml."
  type        = string
  default     = "."
}

variable "dest_server" {
  description = "Cluster the workload is deployed to. The in-cluster default is the cluster ArgoCD itself runs in, which is what we want in all three environments."
  type        = string
  default     = "https://kubernetes.default.svc"
}

variable "dest_namespace" {
  description = "Namespace the workload is deployed into. Must match the `namespace:` hardcoded in billing-getway.yml."
  type        = string
  default     = "billing-gateway"
}
