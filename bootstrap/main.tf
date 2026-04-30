locals {
  oc = "oc --kubeconfig='${var.kubeconfig_path}'"
}

# ─── Phase 0: Validate inputs and cluster prerequisites ───────────────────────

resource "null_resource" "preflight" {
  provisioner "local-exec" {
    command     = <<-EOT
      set -eo pipefail
      "${path.module}/scripts/validate-tfvars.sh"
      "${path.module}/scripts/check-cluster-prereqs.sh"
    EOT
    working_dir = path.module
    environment = {
      TFVARS_PATH         = "${path.module}/terraform.tfvars"
      KUBECONFIG_OVERRIDE = var.kubeconfig_path
    }
  }

  triggers = {
    kubeconfig_path = var.kubeconfig_path
    cluster_name    = var.cluster_name
    gitops_repo_url = var.gitops_repo_url
  }
}

# ─── Phase 1: Install OpenShift GitOps Operator ───────────────────────────────
# Write the Subscription to a file first — nested bash heredocs inside a
# Terraform heredoc cause the terminator to remain indented, so bash never
# closes the document and oc apply receives no input.

resource "local_file" "gitops_subscription" {
  filename        = "${path.module}/.rendered/gitops-subscription.yaml"
  file_permission = "0644"
  content         = <<-YAML
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: openshift-gitops-operator
      namespace: openshift-operators
    spec:
      channel: latest
      installPlanApproval: Automatic
      name: openshift-gitops-operator
      source: redhat-operators
      sourceNamespace: openshift-marketplace
    YAML
}

resource "null_resource" "install_gitops_operator" {
  depends_on = [null_resource.preflight]

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "━━━ Phase 1 — Installing OpenShift GitOps operator ━━━"
      ${local.oc} apply -f '${local_file.gitops_subscription.filename}'
      echo "  ✔  Subscription applied"
    EOT
  }

  triggers = {
    manifest = local_file.gitops_subscription.content
  }
}

# ─── Phase 2: Wait for ArgoCD to be ready ─────────────────────────────────────

resource "null_resource" "wait_gitops" {
  depends_on = [null_resource.install_gitops_operator]

  provisioner "local-exec" {
    command = <<-EOT
      #!/usr/bin/env bash
      set -eo pipefail

      echo ""
      echo "━━━ Phase 2 — Waiting for GitOps operator CSV ━━━"
      for i in $(seq 1 60); do
        STATUS=$(${local.oc} get csv -n openshift-operators \
          -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift GitOps")].status.phase}' \
          2>/dev/null || true)
        if [[ "$STATUS" == "Succeeded" ]]; then
          echo "  ✔  GitOps operator CSV — Succeeded"
          break
        fi
        if [[ $i -eq 60 ]]; then
          echo "  ✘  Timeout: GitOps operator CSV did not reach Succeeded after 10 minutes"
          echo "     Manual check: oc get csv -n openshift-operators | grep gitops"
          exit 1
        fi
        echo "  ·  Attempt $i/60 — CSV status: $${STATUS:-pending}"
        sleep 10
      done

      echo ""
      echo "━━━ Phase 2 — Waiting for ArgoCD server ━━━"
      ${local.oc} wait --for=condition=Available \
        deployment/openshift-gitops-server \
        -n openshift-gitops \
        --timeout=300s
      echo "  ✔  ArgoCD server deployment — Available"

      echo ""
      echo "━━━ Phase 2 — Waiting for ArgoCD application controller ━━━"
      ${local.oc} wait --for=condition=Available \
        deployment/openshift-gitops-application-controller \
        -n openshift-gitops \
        --timeout=300s 2>/dev/null || \
      ${local.oc} wait --for=jsonpath='{.status.readyReplicas}'=1 \
        statefulset/openshift-gitops-application-controller \
        -n openshift-gitops \
        --timeout=300s
      echo "  ✔  ArgoCD application controller — Ready"

      echo ""
      echo "━━━ Phase 2 — Verification ━━━"
      echo ""
      echo "  Operator CSV:"
      ${local.oc} get csv -n openshift-operators \
        --no-headers 2>/dev/null \
        | grep -i gitops \
        | awk '{printf "    %-45s %s\n", $1, $NF}' \
        || echo "    (none found)"

      echo ""
      echo "  ArgoCD pods:"
      ${local.oc} get pods -n openshift-gitops \
        --no-headers 2>/dev/null \
        | awk '{printf "    %-55s %s\n", $1, $3}' \
        || echo "    (none found)"
    EOT
  }

  triggers = {
    operator = null_resource.install_gitops_operator.id
  }
}

# ─── Phase 3: Grant ArgoCD cluster-wide access ────────────────────────────────

resource "kubernetes_cluster_role_binding" "argocd_cluster_admin" {
  depends_on = [null_resource.wait_gitops]

  metadata {
    name = "openshift-gitops-cluster-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "openshift-gitops-argocd-application-controller"
    namespace = "openshift-gitops"
  }
}

# ─── Phase 4: Optional — configure private repo credentials ───────────────────

resource "kubernetes_secret" "argocd_repo_creds" {
  count      = var.git_username != "" ? 1 : 0
  depends_on = [null_resource.wait_gitops]

  metadata {
    name      = "argocd-repo-${var.cluster_name}"
    namespace = "openshift-gitops"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.gitops_repo_url
    username = var.git_username
    password = var.git_token
  }
}

# ─── Phase 5: Render the ApplicationSet ───────────────────────────────────────
# Terraform renders the ApplicationSet to gitops/applicationset.yaml (tracked).
# After terraform apply: git add gitops/applicationset.yaml && git commit && push.
# The root Application reads this file from git when you manually sync it.

resource "local_file" "applicationset" {
  content = templatefile("${path.module}/../gitops/applicationset.yaml.tpl", {
    gitops_repo_url        = var.gitops_repo_url
    gitops_repo_revision   = var.gitops_repo_revision
    gitops_components_path = var.gitops_components_path
    enable_gpu             = var.enable_gpu
  })
  filename        = "${path.module}/../gitops/applicationset.yaml"
  file_permission = "0644"
}

# ─── Phase 6: Render and apply the root Application ───────────────────────────
# ai-ml-root has MANUAL sync. Syncing it once in ArgoCD creates the
# ApplicationSet, which then auto-deploys all AI/ML components.

resource "local_file" "root_application" {
  content = templatefile("${path.module}/../gitops/root-application.yaml.tpl", {
    gitops_repo_url      = var.gitops_repo_url
    gitops_repo_revision = var.gitops_repo_revision
  })
  filename        = "${path.module}/.rendered/root-application.yaml"
  file_permission = "0644"
}

resource "null_resource" "apply_root_application" {
  depends_on = [
    null_resource.wait_gitops,
    kubernetes_cluster_role_binding.argocd_cluster_admin,
    local_file.root_application,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "━━━ Phase 6 — Applying root Application (ai-ml-root) ━━━"
      ${local.oc} apply -f '${local_file.root_application.filename}'
      echo "  ✔  Root Application applied (sync: manual)"

      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  Bootstrap complete"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      ARGOCD_HOST=$(${local.oc} get route openshift-gitops-server \
        -n openshift-gitops \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
      if [ -n "$ARGOCD_HOST" ]; then
        echo "  ArgoCD console : https://$${ARGOCD_HOST}"
      else
        echo "  ArgoCD console : route not yet available — run:"
        echo "    oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}'"
      fi
      echo ""
      echo "  Next steps:"
      echo "    1. git add gitops/applicationset.yaml && git commit && git push"
      echo "    2. Open ArgoCD → sync the 'ai-ml-root' Application"
      echo ""
    EOT
  }

  triggers = {
    content = local_file.root_application.content
  }
}
