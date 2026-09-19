# The ArgoCD Application, with the image tag pinned.
#
# `spec.source.kustomize.images` is a kustomize image override: ArgoCD renders
# kustomization.yaml at the repo root and then rewrites any container image
# whose *name* matches, keeping the name and replacing the tag. So the
# Deployment's `autofikbyslaap/dev.api.billing.getway:master` in
# billing-getway.yml becomes `...:dev-1.2.3` at sync time, without that file
# ever being edited.
#
# Changing this value rewrites the Application spec, which the ArgoCD
# application controller notices immediately - it does not wait for the next
# 3-minute poll - so the rollout starts as soon as the apply lands.
resource "kubernetes_manifest" "billing_gateway_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = var.app_name
      namespace = var.argocd_namespace
    }

    spec = {
      project = var.argocd_project

      source = {
        repoURL        = var.repo_url
        targetRevision = var.target_revision
        path           = var.source_path

        kustomize = {
          images = ["${var.image_repository}:${var.image_tag}"]
        }
      }

      destination = {
        server    = var.dest_server
        namespace = var.dest_namespace
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
        ]
      }
    }
  }

  # ArgoCD's controller writes to this same object (status, operation state,
  # its own labels). Without force_conflicts a server-side apply from
  # Terraform is rejected the moment the controller has touched a field
  # Terraform also declares.
  field_manager {
    name            = "terraform-billing-getway"
    force_conflicts = true
  }

  # Fields other controllers own. Leaving them computed stops every plan
  # showing a diff for something Terraform never set.
  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "metadata.finalizers",
    "status",
  ]
}
