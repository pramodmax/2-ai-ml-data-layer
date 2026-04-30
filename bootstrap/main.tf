locals {
  oc = "oc --kubeconfig='${var.kubeconfig_path}'"
}

# ─── Phase 0: Validate inputs and cluster prerequisites ───────────────────────
# Runs two scripts before any cluster resources are touched:
#   validate-tfvars.sh       — checks all required tfvars are filled in
#   check-cluster-prereqs.sh — checks OCP version, permissions, OperatorHub

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
# Uses oc apply rather than kubernetes_manifest so the plan phase does not
# require the Subscription CRD schema to be resolved by the provider.
# The operator automatically provisions an ArgoCD instance in openshift-gitops.

resource "null_resource" "install_gitops_operator" {
  depends_on = [null_resource.preflight]

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | ${local.oc} apply -f -
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
    EOT
  }

  triggers = {
    subscription = "openshift-gitops-operator"
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
      echo "━━━ Waiting for OpenShift GitOps operator CSV ━━━"
      for i in $(seq 1 60); do
        STATUS=$(${local.oc} get csv -n openshift-operators \
          -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift GitOps")].status.phase}' \
          2>/dev/null || true)
        if [[ "$STATUS" == "Succeeded" ]]; then
          echo "  ✔  GitOps operator CSV is Succeeded"
          break
        fi
        if [[ $i -eq 60 ]]; then
          echo "  ✘  Timeout waiting for GitOps operator CSV after 10 minutes"
          exit 1
        fi
        echo "  ·  Attempt $i/60 — CSV status: $${STATUS:-pending}"
        sleep 10
      done

      echo ""
      echo "━━━ Waiting for ArgoCD server deployment ━━━"
      ${local.oc} wait --for=condition=Available \
        deployment/openshift-gitops-server \
        -n openshift-gitops \
        --timeout=300s
      echo "  ✔  ArgoCD server is Available"

      echo ""
      echo "━━━ Waiting for ArgoCD application controller ━━━"
      ${local.oc} wait --for=condition=Available \
        deployment/openshift-gitops-application-controller \
        -n openshift-gitops \
        --timeout=300s 2>/dev/null || \
      ${local.oc} wait --for=jsonpath='{.status.readyReplicas}'=1 \
        statefulset/openshift-gitops-application-controller \
        -n openshift-gitops \
        --timeout=300s
      echo "  ✔  ArgoCD application controller is ready"
    EOT
  }

  triggers = {
    operator = null_resource.install_gitops_operator.id
  }
}

# ─── Phase 3: Grant ArgoCD cluster-wide access ────────────────────────────────
# The ArgoCD application controller needs cluster-admin to create operator
# subscriptions, CRDs, and other cluster-scoped resources on behalf of GitOps.

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
# Terraform renders the ApplicationSet with real values (repo URL, enable_gpu)
# and writes it to gitops/applicationset.yaml — a tracked file in this repo.
#
# After terraform apply completes:
#   git add gitops/applicationset.yaml && git commit && git push
#
# The root Application (applied in Phase 6) reads this file from git and applies
# the ApplicationSet when you manually sync it in the ArgoCD console.

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
# The root Application has MANUAL sync. It watches gitops/applicationset.yaml
# in the git repo. When you manually sync it in ArgoCD:
#   1. ArgoCD applies the ApplicationSet from git.
#   2. The ApplicationSet discovers gitops/core/* (and gitops/opt/* if GPU
#      is enabled) and creates one Application per directory.
#   3. Each child Application has automated sync and self-heals from git.
#
# This gives you a single sync gate: approve the root Application sync once,
# and the entire AI/ML stack reconciles automatically from that point on.

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
      ${local.oc} apply -f '${local_file.root_application.filename}'

      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  Bootstrap complete"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      ARGOCD_HOST=$(${local.oc} get route openshift-gitops-server \
        -n openshift-gitops \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
      if [[ -n "$ARGOCD_HOST" ]]; then
        echo "  ArgoCD console:  https://$${ARGOCD_HOST}"
      else
        echo "  ArgoCD console:  oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='https://{.spec.host}'"
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
