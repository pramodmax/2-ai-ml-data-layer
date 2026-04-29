output "argocd_url" {
  description = "URL of the ArgoCD console."
  value       = "Run: oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'"
}

output "argocd_password_command" {
  description = "Command to retrieve the ArgoCD initial admin password."
  value       = "oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\\.password}' | base64 -d"
}

output "applicationset_name" {
  description = "Name of the ApplicationSet managing all AI/ML components."
  value       = "ai-ml-data-layer (namespace: openshift-gitops)"
}

output "next_steps" {
  description = "What happens after bootstrap completes."
  value       = <<-EOT

    Bootstrap complete. ArgoCD is now managing the AI/ML stack via GitOps.

    Monitor sync status:
      oc get applications -n openshift-gitops

    Watch all components reconcile:
      oc get applicationsets,applications -n openshift-gitops

    Check operator installation progress:
      oc get csv -A

    Access ArgoCD console:
      oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}'
  EOT
}
