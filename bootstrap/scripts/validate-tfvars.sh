#!/usr/bin/env bash
# Validates bootstrap/terraform.tfvars before running terraform apply.
# Run manually:  ./scripts/validate-tfvars.sh
# Called by Terraform null_resource.validate_inputs before any cluster work.
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

FAILED=()
WARNED=()

pass() { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; FAILED+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; WARNED+=("$1"); }

# ─── Locate terraform.tfvars ──────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS_FILE="${TFVARS_PATH:-${BOOTSTRAP_DIR}/terraform.tfvars}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           terraform.tfvars Validation                        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║  ✘  terraform.tfvars not found                               ║${NC}"
  echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${RED}║  Create it from the example file before running Terraform.  ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Run:"
  echo "    cd bootstrap"
  echo "    cp terraform.tfvars.example terraform.tfvars"
  echo "    \$EDITOR terraform.tfvars"
  echo ""
  echo "  Required fields:"
  echo "    kubeconfig_path  — path to the cluster kubeconfig file"
  echo "    cluster_name     — short name for this cluster"
  echo "    gitops_repo_url  — URL of your fork of this repository"
  echo ""
  exit 1
fi

pass "terraform.tfvars found at: ${TFVARS_FILE}"
echo ""

# ─── Parser ───────────────────────────────────────────────────────────────────
# Strips leading key=, captures content between the first pair of double-quotes.
# Uses ^[^=]*= (anchored, non-greedy) so = signs inside values are never eaten.
get_var() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS_FILE" 2>/dev/null \
    | head -1 \
    | sed 's/^[^=]*=[[:space:]]*//' \
    | sed 's/^"\([^"]*\)".*/\1/' \
    | tr -d '\r' \
    || true
}

# ─── Required: kubeconfig_path ───────────────────────────────────────────────

echo -e "${BOLD}  Cluster Access${NC}"
echo ""

KUBECONFIG_PATH=$(get_var "kubeconfig_path")
if [[ -z "$KUBECONFIG_PATH" ]]; then
  fail "kubeconfig_path is empty"
else
  # Expand ~ or relative paths relative to the bootstrap directory
  EXPANDED_PATH="${KUBECONFIG_PATH/#\~/$HOME}"
  if [[ "${EXPANDED_PATH}" != /* ]]; then
    EXPANDED_PATH="${BOOTSTRAP_DIR}/${EXPANDED_PATH}"
  fi
  if [[ ! -f "$EXPANDED_PATH" ]]; then
    fail "kubeconfig_path = '${KUBECONFIG_PATH}' — file not found at ${EXPANDED_PATH}"
  else
    pass "kubeconfig_path = ${KUBECONFIG_PATH}"
  fi
fi

KUBECONFIG_CONTEXT=$(get_var "kubeconfig_context")
if [[ -z "$KUBECONFIG_CONTEXT" ]]; then
  pass "kubeconfig_context — using current context in kubeconfig"
else
  pass "kubeconfig_context = ${KUBECONFIG_CONTEXT}"
fi

# ─── Required: cluster_name ──────────────────────────────────────────────────

CLUSTER_NAME=$(get_var "cluster_name")
if [[ -z "$CLUSTER_NAME" ]]; then
  fail "cluster_name is empty"
elif [[ "$CLUSTER_NAME" == "demo-ocp" ]]; then
  warn "cluster_name is the example value 'demo-ocp' — update if this is not your cluster name"
elif ! echo "$CLUSTER_NAME" | grep -qE '^[a-z][a-z0-9-]{1,26}[a-z0-9]$'; then
  fail "cluster_name '${CLUSTER_NAME}' is invalid — must be 3-28 chars, lowercase letters, digits, hyphens, start with a letter"
else
  pass "cluster_name = ${CLUSTER_NAME}"
fi

# ─── Required: gitops_repo_url ───────────────────────────────────────────────

echo ""
echo -e "${BOLD}  GitOps Repository${NC}"
echo ""

GITOPS_URL=$(get_var "gitops_repo_url")
if [[ -z "$GITOPS_URL" ]]; then
  warn "gitops_repo_url is not set — ArgoCD will have no repo to sync from until you set this"
elif [[ "$GITOPS_URL" == *"your-org"* ]] || [[ "$GITOPS_URL" == *"your-repo"* ]]; then
  warn "gitops_repo_url looks like the example placeholder — update it to your actual repository URL"
elif [[ "$GITOPS_URL" != http* ]] && [[ "$GITOPS_URL" != git@* ]]; then
  fail "gitops_repo_url '${GITOPS_URL}' does not look like a valid git URL (expected https:// or git@)"
else
  pass "gitops_repo_url = ${GITOPS_URL}"
fi

GITOPS_REVISION=$(get_var "gitops_repo_revision")
GITOPS_REVISION="${GITOPS_REVISION:-main}"
pass "gitops_repo_revision = ${GITOPS_REVISION}"

GITOPS_PATH=$(get_var "gitops_components_path")
GITOPS_PATH="${GITOPS_PATH:-gitops/components}"
pass "gitops_components_path = ${GITOPS_PATH}"

# ─── Optional: private repo credentials ──────────────────────────────────────

echo ""
echo -e "${BOLD}  Private Repository (optional)${NC}"
echo ""

GIT_USERNAME=$(get_var "git_username")
GIT_TOKEN=$(get_var "git_token")

if [[ -z "$GIT_USERNAME" ]] && [[ -z "$GIT_TOKEN" ]]; then
  pass "git_username / git_token — not set (public repository)"
elif [[ -n "$GIT_USERNAME" ]] && [[ -z "$GIT_TOKEN" ]]; then
  fail "git_username is set but git_token is empty — both must be provided for private repo access"
elif [[ -z "$GIT_USERNAME" ]] && [[ -n "$GIT_TOKEN" ]]; then
  fail "git_token is set but git_username is empty — both must be provided for private repo access"
else
  pass "git_username = ${GIT_USERNAME}"
  pass "git_token — set (not shown)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "${#FAILED[@]}" -eq 0 ]]; then
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  terraform.tfvars is complete                             ║${NC}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${GREEN}║  All required values are present and look valid.             ║${NC}"
  echo -e "${BOLD}${GREEN}║  You are ready to run: terraform plan / terraform apply      ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  exit 0
fi

echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║  ✘  terraform.tfvars has missing or invalid values           ║${NC}"
echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${RED}║  Fix the issues below before running terraform apply.        ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}  Issues to fix:${NC}"
echo ""

for f in "${FAILED[@]}"; do
  case "$f" in
    *"kubeconfig_path is empty"*)
      echo -e "  ${RED}✘${NC}  ${BOLD}kubeconfig_path${NC}"
      echo "     Set the path to your cluster kubeconfig:"
      echo "       kubeconfig_path = \"../1-ocp-on-aws/clusters/my-cluster/auth/kubeconfig\""
      echo "     Or point to an existing kubeconfig:"
      echo "       kubeconfig_path = \"~/.kube/config\""
      echo ""
      ;;
    *"kubeconfig_path"*"file not found"*)
      echo -e "  ${RED}✘${NC}  ${BOLD}kubeconfig_path${NC}"
      echo "     The kubeconfig file does not exist at the specified path."
      echo "     Verify the path or log in to the cluster to generate it:"
      echo "       oc login --server=https://api.<cluster>.<domain>:6443 --kubeconfig=/path/to/kubeconfig"
      echo ""
      ;;
    *"cluster_name"*)
      echo -e "  ${RED}✘${NC}  ${BOLD}cluster_name${NC}"
      echo "     Set a short lowercase identifier for this cluster (3–28 chars):"
      echo "       cluster_name = \"my-ai-cluster\""
      echo ""
      ;;
    *"git_username"*"git_token"* | *"git_token"*"git_username"*)
      echo -e "  ${RED}✘${NC}  ${BOLD}git_username / git_token${NC}"
      echo "     Both must be set together for private repository access."
      echo "     For a public repository, leave both empty (comment them out)."
      echo ""
      ;;
    *)
      echo -e "  ${RED}✘${NC}  ${f}"
      echo ""
      ;;
  esac
done

echo -e "  Edit ${BOLD}bootstrap/terraform.tfvars${NC} and re-run:"
echo "    ./scripts/validate-tfvars.sh"
echo ""
exit 1
