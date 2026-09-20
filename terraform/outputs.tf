output "environment" {
  description = "The environment this state manages. CI echoes it back as a check that `init` selected the right state Secret."
  value       = var.environment
}

output "deployed_image" {
  description = "The exact image ArgoCD will roll out. The deploy workflow waits until the live Deployment reports this value."
  value       = local.image
}

output "replicas" {
  description = "Replica count ArgoCD overrides the Deployment with."
  value       = local.replicas
}

output "app_name" {
  description = "Name of the ArgoCD Application."
  value       = var.app_name
}

output "argocd_namespace" {
  description = "Namespace the Application lives in."
  value       = var.argocd_namespace
}

output "dest_namespace" {
  description = "Namespace the workload runs in."
  value       = var.dest_namespace
}

output "application" {
  description = "Where to watch the rollout."
  value       = "kubectl -n ${var.argocd_namespace} get application ${var.app_name}"
}
