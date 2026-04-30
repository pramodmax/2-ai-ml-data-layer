output "argocd_url" {
  description = "Command to retrieve the ArgoCD console URL."
  value       = "oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}'"
}

output "argocd_password_command" {
  description = "Command to retrieve the ArgoCD initial admin password."
  value       = "oc get secret openshift-gitops-cluster -n openshift-gitops -o jsonpath='{.data.admin\\.password}' | base64 -d"
}

output "verify_gitops" {
  description = "Commands to manually verify OpenShift GitOps installation."
  value       = <<-EOT

    ── Verify OpenShift GitOps operator ──────────────────────────────────────

      # CSV must show phase = Succeeded
      oc get csv -n openshift-operators | grep -i gitops

      # Subscription must show state = AtLatestKnown
      oc get subscription openshift-gitops-operator -n openshift-operators

      # InstallPlan must be Approved + Complete
      oc get installplan -n openshift-operators

    ── Verify ArgoCD instance ─────────────────────────────────────────────────

      # All pods must be Running/Ready
      oc get pods -n openshift-gitops

      # Route must exist and be reachable
      oc get route openshift-gitops-server -n openshift-gitops

      # ArgoCD console URL
      oc get route openshift-gitops-server -n openshift-gitops \
        -o jsonpath='https://{.spec.host}'

      # Admin password
      oc get secret openshift-gitops-cluster -n openshift-gitops \
        -o jsonpath='{.data.admin\.password}' | base64 -d && echo

    ── Verify root Application ────────────────────────────────────────────────

      # ai-ml-root must exist (OutOfSync until you push + sync)
      oc get application ai-ml-root -n openshift-gitops

  EOT
}

output "next_steps" {
  description = "Required steps after terraform apply completes."
  value       = <<-EOT

    ── Bootstrap complete ─────────────────────────────────────────────────────

    1. Commit the rendered ApplicationSet so ArgoCD can read it from git:

         git add gitops/applicationset.yaml
         git commit -m "chore: add rendered ApplicationSet"
         git push

    2. Open the ArgoCD console and manually sync ai-ml-root:

         oc get route openshift-gitops-server -n openshift-gitops \
           -o jsonpath='https://{.spec.host}'

         ArgoCD UI : Applications → ai-ml-root → Sync → Synchronize
         CLI       : argocd app sync ai-ml-root

    After the sync, the ApplicationSet deploys all AI/ML components
    automatically in sync-wave order (~20–40 min).

  EOT
}
