output "argocd_url" {
  description = "URL of the ArgoCD console."
  value       = "Run: oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}'"
}

output "argocd_password_command" {
  description = "Command to retrieve the ArgoCD initial admin password."
  value       = "oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\\.password}' | base64 -d"
}

output "next_steps" {
  description = "Required steps after terraform apply completes."
  value       = <<-EOT

    ─── Bootstrap complete ───────────────────────────────────────────────────────

    ArgoCD is running. The root Application (ai-ml-root) has been created with
    MANUAL sync. Nothing deploys to the cluster until you complete these steps:

    Step 1 — Commit the rendered ApplicationSet to git:

      git add gitops/applicationset.yaml
      git commit -m "chore: add rendered ApplicationSet"
      git push

    Step 2 — Open the ArgoCD console and sync the root Application:

      oc get route openshift-gitops-server -n openshift-gitops \
        -o jsonpath='https://{.spec.host}'

      In the ArgoCD UI: Applications → ai-ml-root → Sync → Synchronize

      Or via CLI:
      argocd app sync ai-ml-root

    After the root Application syncs, the ApplicationSet is created and ArgoCD
    automatically deploys all AI/ML components in sync-wave order (~20-40 min).

    ─── Monitor progress ─────────────────────────────────────────────────────────

      # Watch Applications appear and sync
      oc get applications -n openshift-gitops -w

      # Check operator install status
      oc get csv -A --watch

    ─── ArgoCD credentials ───────────────────────────────────────────────────────

      oc get secret openshift-gitops-cluster -n openshift-gitops \
        -o jsonpath='{.data.admin\.password}' | base64 -d && echo

  EOT
}
