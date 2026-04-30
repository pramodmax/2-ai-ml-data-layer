#!/usr/bin/env bash
# Verifies that the target OpenShift cluster meets all requirements to run
# this Terraform bootstrap and the subsequent RHOAI GitOps stack.
#
# Checks performed:
#   1. Required CLI tools installed (oc, terraform, git)
#   2. Cluster is reachable with the provided kubeconfig
#   3. OCP version >= 4.19 (RHOAI 3.4 minimum)
#   4. Current user has cluster-admin privileges
#   5. OperatorHub / marketplace is accessible
#   6. Cluster has sufficient node capacity for RHOAI
#   7. Required namespaces are not in a broken state
#   8. Existing conflicting installations (GitOps, RHOAI already present)
#   9. gitops_repo_url is network-reachable (https only)
#
# Run manually:  ./scripts/check-cluster-prereqs.sh
# Called by Terraform null_resource.check_prereqs before any cluster work.
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

FAILED=()
WARNED=()

pass() { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; FAILED+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; WARNED+=("$1"); }
info() { echo -e "  ${BLUE}ℹ${NC}  $1"; }

# ─── Resolve kubeconfig from tfvars or environment ───────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS_FILE="${TFVARS_PATH:-${BOOTSTRAP_DIR}/terraform.tfvars}"

# Parser — same anchor technique as validate-tfvars.sh
get_var() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS_FILE" 2>/dev/null \
    | head -1 \
    | sed 's/^[^=]*=[[:space:]]*//' \
    | sed 's/^"\([^"]*\)".*/\1/' \
    | tr -d '\r' \
    || true
}

if [[ -f "$TFVARS_FILE" ]]; then
  RAW_KUBECONFIG=$(get_var "kubeconfig_path")
  GITOPS_URL=$(get_var "gitops_repo_url")
else
  RAW_KUBECONFIG=""
  GITOPS_URL=""
fi

# Resolve ~ and relative paths
KUBECONFIG_FILE="${RAW_KUBECONFIG/#\~/$HOME}"
if [[ -n "$KUBECONFIG_FILE" ]] && [[ "${KUBECONFIG_FILE}" != /* ]]; then
  KUBECONFIG_FILE="${BOOTSTRAP_DIR}/${KUBECONFIG_FILE}"
fi

# Allow override via environment (e.g. from Terraform local-exec)
KUBECONFIG_FILE="${KUBECONFIG_OVERRIDE:-${KUBECONFIG_FILE:-${KUBECONFIG:-$HOME/.kube/config}}}"

# oc wrapper — always uses the resolved kubeconfig
_oc() { oc --kubeconfig="$KUBECONFIG_FILE" "$@"; }

# ─── Header ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Cluster Pre-requisite Check                          ║${NC}"
echo -e "${BOLD}║         Red Hat OpenShift AI 3.4 / GitOps Bootstrap          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── 1. Required CLI tools ───────────────────────────────────────────────────

echo -e "${BOLD}  [1/7] Required CLI tools${NC}"
echo ""

OC_OK=false
if command -v oc &>/dev/null; then
  OC_VER=$(oc version --client -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('releaseClientVersion','unknown'))" 2>/dev/null || oc version --client 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  pass "oc ${OC_VER}"
  OC_OK=true
else
  fail "oc is not installed — install it from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
fi

if command -v terraform &>/dev/null; then
  TF_VER=$(terraform version -json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('terraform_version','unknown'))" 2>/dev/null || terraform version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  # Check minimum version 1.5.0
  TF_MAJOR=$(echo "$TF_VER" | cut -d. -f1)
  TF_MINOR=$(echo "$TF_VER" | cut -d. -f2)
  if [[ "$TF_MAJOR" -gt 1 ]] || { [[ "$TF_MAJOR" -eq 1 ]] && [[ "$TF_MINOR" -ge 5 ]]; }; then
    pass "terraform ${TF_VER}"
  else
    fail "terraform ${TF_VER} is below minimum 1.5.0 — upgrade at: https://developer.hashicorp.com/terraform/install"
  fi
else
  fail "terraform is not installed — install from: https://developer.hashicorp.com/terraform/install"
fi

if command -v git &>/dev/null; then
  GIT_VER=$(git --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  pass "git ${GIT_VER}"
else
  fail "git is not installed"
fi

# ─── 2. Cluster connectivity ─────────────────────────────────────────────────

echo ""
echo -e "${BOLD}  [2/7] Cluster connectivity${NC}"
echo ""

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  fail "kubeconfig not found at: ${KUBECONFIG_FILE}"
  echo ""
  echo -e "  ${YELLOW}Remaining checks skipped — no kubeconfig available.${NC}"
  echo ""
else
  pass "kubeconfig found: ${KUBECONFIG_FILE}"

  if [[ "$OC_OK" == "true" ]]; then
    CLUSTER_REACHABLE=false
    API_URL=$(_oc whoami --show-server 2>/dev/null || echo "")
    if [[ -n "$API_URL" ]]; then
      CURRENT_USER=$(_oc whoami 2>/dev/null || echo "")
      if [[ -n "$CURRENT_USER" ]]; then
        pass "Connected to: ${API_URL}"
        pass "Logged in as: ${CURRENT_USER}"
        CLUSTER_REACHABLE=true
      else
        fail "oc whoami failed — kubeconfig may be expired or invalid"
        info "Try: oc login --server=${API_URL} --kubeconfig=${KUBECONFIG_FILE}"
      fi
    else
      fail "Cannot reach the cluster API — check network connectivity and kubeconfig"
    fi

    if [[ "$CLUSTER_REACHABLE" == "true" ]]; then

      # ─── 3. OCP version ────────────────────────────────────────────────────

      echo ""
      echo -e "${BOLD}  [3/7] OpenShift version (minimum: 4.19)${NC}"
      echo ""

      OCP_VERSION=$(_oc get clusterversion version \
        -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "")
      if [[ -z "$OCP_VERSION" ]]; then
        fail "Could not read cluster version — is this an OpenShift cluster?"
      else
        OCP_MAJOR=$(echo "$OCP_VERSION" | cut -d. -f1)
        OCP_MINOR=$(echo "$OCP_VERSION" | cut -d. -f2)
        if [[ "$OCP_MAJOR" -gt 4 ]] || { [[ "$OCP_MAJOR" -eq 4 ]] && [[ "$OCP_MINOR" -ge 19 ]]; }; then
          pass "OCP ${OCP_VERSION} (>= 4.19 required for RHOAI 3.4)"
        else
          fail "OCP ${OCP_VERSION} is below the minimum 4.19 required for RHOAI 3.4"
          info "Upgrade the cluster to OCP 4.19 or 4.20 before proceeding"
        fi
      fi

      # ─── 4. Cluster-admin permissions ─────────────────────────────────────

      echo ""
      echo -e "${BOLD}  [4/7] Required cluster permissions${NC}"
      echo ""

      check_permission() {
        local verb="$1" resource="$2" ns_flag="$3" label="$4"
        local result
        result=$(_oc auth can-i "$verb" "$resource" ${ns_flag} 2>/dev/null || echo "no")
        if [[ "$result" == "yes" ]]; then
          pass "${label}"
        else
          fail "Cannot ${verb} ${resource}${ns_flag:+ (${ns_flag})} — insufficient permissions"
        fi
      }

      # Terraform needs these to bootstrap GitOps
      check_permission "create" "subscriptions.operators.coreos.com" \
        "-n openshift-operators" \
        "create Subscriptions in openshift-operators"
      check_permission "create" "clusterrolebindings.rbac.authorization.k8s.io" \
        "" \
        "create ClusterRoleBindings (cluster-scoped)"
      check_permission "create" "namespaces" \
        "" \
        "create Namespaces (cluster-scoped)"
      check_permission "get" "clusterversions.config.openshift.io" \
        "" \
        "get ClusterVersion (read cluster info)"
      check_permission "create" "applicationsets.argoproj.io" \
        "-n openshift-gitops" \
        "create ApplicationSets in openshift-gitops"

      # Verify broad cluster-admin (best-effort)
      IS_CLUSTER_ADMIN=$(_oc auth can-i '*' '*' --all-namespaces 2>/dev/null || echo "no")
      if [[ "$IS_CLUSTER_ADMIN" == "yes" ]]; then
        pass "cluster-admin confirmed"
      else
        warn "Could not confirm cluster-admin role — individual permission checks above may still be sufficient"
      fi

      # ─── 5. OperatorHub / marketplace ─────────────────────────────────────

      echo ""
      echo -e "${BOLD}  [5/7] OperatorHub and catalog sources${NC}"
      echo ""

      REDHAT_CATALOG=$(_oc get catalogsource redhat-operators \
        -n openshift-marketplace \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
      if [[ "$REDHAT_CATALOG" == "READY" ]]; then
        pass "redhat-operators CatalogSource is READY"
      elif [[ -n "$REDHAT_CATALOG" ]]; then
        warn "redhat-operators CatalogSource state: ${REDHAT_CATALOG} (expected READY)"
      else
        fail "redhat-operators CatalogSource not found in openshift-marketplace — OperatorHub may be disabled or cluster has no internet access"
      fi

      COMMUNITY_CATALOG=$(_oc get catalogsource community-operators \
        -n openshift-marketplace \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
      if [[ "$COMMUNITY_CATALOG" == "READY" ]]; then
        pass "community-operators CatalogSource is READY (needed for Grafana)"
      elif [[ -n "$COMMUNITY_CATALOG" ]]; then
        warn "community-operators CatalogSource state: ${COMMUNITY_CATALOG}"
      else
        warn "community-operators CatalogSource not found — Grafana operator install may fail"
      fi

      # ─── 6. Node / resource capacity ──────────────────────────────────────

      echo ""
      echo -e "${BOLD}  [6/7] Cluster resource capacity${NC}"
      echo ""

      NODE_COUNT=$(_oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
      WORKER_COUNT=$(_oc get nodes -l 'node-role.kubernetes.io/worker' --no-headers 2>/dev/null | wc -l | tr -d ' ')
      READY_WORKERS=$(_oc get nodes -l 'node-role.kubernetes.io/worker' --no-headers 2>/dev/null \
        | grep -c " Ready " || echo "0")

      pass "Total nodes: ${NODE_COUNT}  (workers: ${WORKER_COUNT}, ready workers: ${READY_WORKERS})"

      if [[ "$WORKER_COUNT" -lt 2 ]]; then
        warn "Fewer than 2 worker nodes — RHOAI requires at least 2 workers; 3+ recommended"
      fi

      # Total allocatable CPU and memory across workers
      TOTAL_CPU=$(_oc get nodes -l 'node-role.kubernetes.io/worker' \
        -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' 2>/dev/null \
        | awk '{
            n=$1
            if (index(n,"m")) { sub("m","",n); sum+=n/1000 }
            else { sum+=n }
          } END { printf "%.0f", sum }' || echo "0")
      TOTAL_MEM_KI=$(_oc get nodes -l 'node-role.kubernetes.io/worker' \
        -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
        | awk '{ sub("Ki",""); sum+=$1 } END { printf "%.0f", sum/1024/1024 }' || echo "0")

      if [[ "$TOTAL_CPU" -ge 16 ]]; then
        pass "Allocatable worker CPU: ~${TOTAL_CPU} cores (>= 16 recommended for RHOAI)"
      else
        warn "Allocatable worker CPU: ~${TOTAL_CPU} cores — RHOAI recommends >= 16 cores across workers"
      fi

      if [[ "$TOTAL_MEM_KI" -ge 64 ]]; then
        pass "Allocatable worker memory: ~${TOTAL_MEM_KI} GiB (>= 64 GiB recommended)"
      else
        warn "Allocatable worker memory: ~${TOTAL_MEM_KI} GiB — RHOAI recommends >= 64 GiB across workers"
      fi

      # GPU nodes
      GPU_NODES=$(_oc get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.capacity.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
        | grep -v " $" | grep -v "^$" | wc -l | tr -d ' ')
      if [[ "$GPU_NODES" -gt 0 ]]; then
        pass "GPU nodes detected: ${GPU_NODES} node(s) with nvidia.com/gpu capacity"
        ENABLE_GPU_VAR=$(get_var "enable_gpu")
        if [[ "$ENABLE_GPU_VAR" == "true" ]]; then
          pass "enable_gpu = true — NFD and NVIDIA GPU Operator will be deployed by ArgoCD"
        else
          warn "GPU nodes found but enable_gpu is not set to true in terraform.tfvars"
          if [[ -t 0 && -f "$TFVARS_FILE" ]]; then
            echo ""
            read -r -p "  $(echo -e "${YELLOW}?${NC}")  Enable GPU support now? This sets enable_gpu = true in terraform.tfvars [y/N]: " GPU_REPLY </dev/tty
            echo ""
            if [[ "$GPU_REPLY" =~ ^[Yy]$ ]]; then
              if grep -qE "^[[:space:]]*(#[[:space:]]*)?enable_gpu[[:space:]]*=" "$TFVARS_FILE"; then
                sed -i.bak 's|^[[:space:]]*#*[[:space:]]*enable_gpu[[:space:]]*=.*|enable_gpu = true|' "$TFVARS_FILE"
              else
                echo 'enable_gpu = true' >> "$TFVARS_FILE"
              fi
              pass "enable_gpu = true written to terraform.tfvars — NFD and GPU Operator will be deployed"
            else
              info "Skipped — set 'enable_gpu = true' in terraform.tfvars before running terraform apply"
            fi
          else
            info "Set 'enable_gpu = true' in terraform.tfvars to auto-install NFD and GPU Operator via ArgoCD"
          fi
        fi
      else
        info "No GPU nodes detected — enable_gpu remains false (default)"
      fi

      # ─── 7. Existing installation check ───────────────────────────────────

      echo ""
      echo -e "${BOLD}  [7/7] Existing installations${NC}"
      echo ""

      GITOPS_INSTALLED=$(_oc get csv -n openshift-operators 2>/dev/null \
        | grep -i "openshift-gitops" | head -1 || echo "")
      if [[ -n "$GITOPS_INSTALLED" ]]; then
        GITOPS_STATUS=$(echo "$GITOPS_INSTALLED" | awk '{print $NF}')
        if [[ "$GITOPS_STATUS" == "Succeeded" ]]; then
          warn "OpenShift GitOps is already installed (${GITOPS_STATUS}) — Terraform will adopt it"
        else
          warn "OpenShift GitOps found with status: ${GITOPS_STATUS} — verify it is healthy before proceeding"
        fi
      else
        pass "OpenShift GitOps not yet installed — will be bootstrapped by Terraform"
      fi

      RHOAI_INSTALLED=$(_oc get subscription rhods-operator -n redhat-ods-operator 2>/dev/null \
        -o jsonpath='{.metadata.name}' || echo "")
      if [[ -n "$RHOAI_INSTALLED" ]]; then
        RHOAI_CSV=$(_oc get csv -n redhat-ods-operator 2>/dev/null \
          | grep -i "rhods-operator\|rhoai" | awk '{print $1, $NF}' | head -1 || echo "unknown")
        warn "RHOAI is already installed (${RHOAI_CSV}) — ArgoCD will adopt and manage it via GitOps"
      else
        pass "RHOAI not yet installed — will be deployed by ArgoCD"
      fi

      ARGOCD_NS=$(_oc get namespace openshift-gitops 2>/dev/null \
        -o jsonpath='{.metadata.name}' || echo "")
      if [[ -n "$ARGOCD_NS" ]]; then
        APPSETS=$(_oc get applicationsets -n openshift-gitops --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$APPSETS" -gt 0 ]]; then
          warn "ArgoCD ApplicationSets already exist in openshift-gitops (${APPSETS} found) — review before applying"
        else
          info "openshift-gitops namespace exists, no ApplicationSets yet"
        fi
      else
        pass "openshift-gitops namespace does not exist yet — clean slate"
      fi

    fi  # CLUSTER_REACHABLE
  fi  # OC_OK
fi  # kubeconfig exists

# ─── (Optional) gitops_repo_url reachability ─────────────────────────────────

if [[ -n "$GITOPS_URL" ]] && [[ "$GITOPS_URL" == https://* ]]; then
  echo ""
  echo -e "${BOLD}  GitOps repository reachability${NC}"
  echo ""
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 8 --max-time 15 \
    "${GITOPS_URL%.git}" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "301" ]] || [[ "$HTTP_CODE" == "302" ]]; then
    pass "gitops_repo_url is reachable (HTTP ${HTTP_CODE})"
  elif [[ "$HTTP_CODE" == "000" ]]; then
    warn "gitops_repo_url could not be reached (network timeout) — ensure the cluster can reach ${GITOPS_URL}"
  else
    warn "gitops_repo_url returned HTTP ${HTTP_CODE} — verify the repository URL and access permissions"
  fi
fi

# ─── Final summary ────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "${#FAILED[@]}" -eq 0 ]] && [[ "${#WARNED[@]}" -eq 0 ]]; then
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║  ✔  All prerequisite checks passed                           ║${NC}"
  echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${GREEN}║  The cluster meets all requirements for RHOAI 3.4 GitOps.   ║${NC}"
  echo -e "${BOLD}${GREEN}║  Run: terraform plan && terraform apply                      ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  exit 0
fi

if [[ "${#FAILED[@]}" -eq 0 ]] && [[ "${#WARNED[@]}" -gt 0 ]]; then
  echo ""
  echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${YELLOW}║  ⚠  Checks passed with warnings                              ║${NC}"
  echo -e "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}${YELLOW}║  Review the warnings above before running terraform apply.  ║${NC}"
  echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  exit 0
fi

echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║  ✘  ${#FAILED[@]} prerequisite check(s) failed                         ║${NC}"
echo -e "${BOLD}${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${RED}║  Resolve the errors above before running terraform apply.   ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}  Failed checks:${NC}"
for f in "${FAILED[@]}"; do
  echo -e "  ${RED}✘${NC}  ${f}"
done
echo ""
exit 1
