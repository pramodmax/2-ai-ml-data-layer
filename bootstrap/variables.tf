# ─── Cluster Access ───────────────────────────────────────────────────────────

variable "kubeconfig_path" {
  description = <<-EOT
    Path to the kubeconfig file for the target cluster.
    If using the companion 1-ocp-on-aws project, this is:
      ../1-ocp-on-aws/clusters/<cluster-name>/auth/kubeconfig
  EOT
  type        = string
}

variable "kubeconfig_context" {
  description = "Kubernetes context name from the kubeconfig. Leave empty to use the current context."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Name of the OpenShift cluster. Used for labelling and resource naming."
  type        = string
}

# ─── GitOps Repository ────────────────────────────────────────────────────────

variable "gitops_repo_url" {
  description = <<-EOT
    Git repository URL that ArgoCD will sync from.
    This should be the URL of your fork/clone of this repository.
    Example: https://github.com/your-org/2-ai-ml-data-layer.git
  EOT
  type        = string
}

variable "gitops_repo_revision" {
  description = "Git branch, tag, or commit SHA for ArgoCD to track."
  type        = string
  default     = "main"
}

variable "gitops_components_path" {
  description = "Path within the repository to the GitOps component directories."
  type        = string
  default     = "gitops/core"
}

# ─── Private Repository (optional) ───────────────────────────────────────────

variable "git_username" {
  description = "Git username for private repository access. Leave empty for public repos."
  type        = string
  default     = ""
}

variable "git_token" {
  description = "Git personal access token for private repository access. Leave empty for public repos."
  type        = string
  sensitive   = true
  default     = ""
}
