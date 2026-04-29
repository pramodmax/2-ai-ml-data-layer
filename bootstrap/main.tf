locals {
  oc = "oc --kubeconfig='${var.kubeconfig_path}'"
}

# ─── Phase 0: Validate inputs and cluster prerequisites ───────────────────────
# Runs two scripts before any cluster resources are touched:
#   validate-tfvars.sh   — checks all required tfvars are filled in
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
      TFVARS_PATH        = "${path.module}/terraform.tfvars"
      KUBECONFIG_OVERRIDE = var.kubeconfig_path
    }
  }

  triggers = {
    kubeconfig_path  = var.kubeconfig_path
    cluster_name     = var.cluster_name
    gitops_repo_url  = var.gitops_repo_url
  }
}

# ─── Phase 1: Install OpenShift GitOps Operator ───────────────────────────────
# The subscription installs the operator from OperatorHub. The operator then
# automatically provisions an ArgoCD instance in the openshift-gitops namespace.

resource "kubernetes_manifest" "gitops_subscription" {
  depends_on = [null_resource.preflight]

  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "openshift-gitops-operator"
      namespace = "openshift-operators"
    }
    spec = {
      channel             = "latest"
      installPlanApproval = "Automatic"
      name                = "openshift-gitops-operator"
      source              = "redhat-operators"
      sourceNamespace     = "openshift-marketplace"
    }
  }
}

# ─── Phase 2: Wait for ArgoCD to be ready ─────────────────────────────────────

resource "null_resource" "wait_gitops" {
  depends_on = [kubernetes_manifest.gitops_subscription]

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
        echo "  ·  Attempt $i/60 — CSV status: ${STATUS:-pending}"
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
    subscription = kubernetes_manifest.gitops_subscription.manifest["metadata"]["name"]
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

# ─── Phase 5: Render and apply the ApplicationSet ─────────────────────────────
# The ApplicationSet uses the git directory generator to discover every
# directory under gitops/components/ and create one ArgoCD Application per
# directory. Adding a new component is a directory drop-in — no Terraform
# changes needed.

resource "local_file" "applicationset" {
  content = templatefile("${path.module}/../gitops/applicationset.yaml.tpl", {
    gitops_repo_url        = var.gitops_repo_url
    gitops_repo_revision   = var.gitops_repo_revision
    gitops_components_path = var.gitops_components_path
  })
  filename        = "${path.module}/.rendered/applicationset.yaml"
  file_permission = "0644"
}

resource "null_resource" "apply_applicationset" {
  depends_on = [
    null_resource.wait_gitops,
    kubernetes_cluster_role_binding.argocd_cluster_admin,
    local_file.applicationset,
  ]

  provisioner "local-exec" {
    command = "${local.oc} apply -f '${local_file.applicationset.filename}'"
  }

  triggers = {
    content = local_file.applicationset.content
  }
}
