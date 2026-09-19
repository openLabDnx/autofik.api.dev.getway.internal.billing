output "deployed_image" {
  description = "The exact image ArgoCD will roll out."
  value       = "${var.image_repository}:${var.image_tag}"
}

output "application" {
  description = "Where to watch the rollout."
  value       = "kubectl -n ${var.argocd_namespace} get application ${var.app_name}"
}
