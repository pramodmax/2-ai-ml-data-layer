# AI/ML Data Layer — GitOps Bootstrap

Terraform bootstrap + GitOps manifests for deploying a production-ready AI/ML platform on Red Hat OpenShift. Terraform installs OpenShift GitOps (ArgoCD) and registers one ApplicationSet; from that point ArgoCD owns the full stack.

**Platform versions:** OpenShift AI 3.4 · OCP 4.19–4.20

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster (OCP 4.19+)                        │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                     GitOps Control Plane                              │  │
│  │                                                                       │  │
│  │   ┌─────────────────────────────────────────────────────────────┐    │  │
│  │   │            OpenShift GitOps  (ArgoCD)                       │    │  │
│  │   │   Bootstrapped by Terraform · Manages everything below      │    │  │
│  │   └──────────────────────┬──────────────────────────────────────┘    │  │
│  │                          │  ApplicationSet (git directory generator)  │  │
│  └──────────────────────────┼──────────────────────────────────────────-┘  │
│                             │                                               │
│              ┌──────────────┴──────────────────────────────────────┐        │
│              │  gitops/core/*  (always deployed)                   │        │
│              │                                                      │        │
│        ┌─────┴──────┐  ┌──────────────────┐  ┌───────────────────┐│        │
│        │ Namespaces │  │Platform Operators │  │    Monitoring     ││        │
│        │ AppSet -20 │  │  (waves 0 → 1)   │  │  (waves -5→15)   ││        │
│        │            │  │                  │  │                   ││        │
│        │cert-mgr-op │  │ cert-manager     │  │ User Workload     ││        │
│        │kueue-op    │  │ Kueue + JobSet   │  │ Monitoring        ││        │
│        │jobset-op   │  │ OCP Pipelines    │  │ (Prometheus)      ││        │
│        │rhsso       │  │ Red Hat SSO      │  │                   ││        │
│        │vault       │  │ Vault Secrets Op │  │ Grafana Operator  ││        │
│        │grafana     │  └──────────────────┘  │ (ML dashboards)  ││        │
│        │rhoai-regs  │                         └───────────────────┘│        │
│        │data-sci-   │  ┌──────────────────────────────────────────┐│        │
│        │ project    │  │  Secret Management + Object Storage      ││        │
│        └────────────┘  │                                          ││        │
│                        │  AppSet -10 ▸ HashiCorp Vault            ││        │
│                        │  StatefulSet · 10Gi PVC · init Job       ││        │
│                        │  KV-v2 + K8s auth + roles + KV paths     ││        │
│                        │               ▼                          ││        │
│                        │  AppSet -5  ▸ Vault Secrets Operator     ││        │
│                        │  VaultStaticSecret CRs (KV → Secrets)    ││        │
│                        │               ▼                          ││        │
│                        │  AppSet 0   ▸ Object Storage             ││        │
│                        │  RustFS (S3-compat., in-cluster)         ││        │
│                        │  s3-credentials → redhat-ods-apps        ││        │
│                        └──────────────────────────────────────────┘│        │
│                                                                      │        │
│              └──────────────────────────────────────────────────────┘        │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │         Red Hat OpenShift AI 3.4   (waves 1 → 20)                    │  │
│  │                                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────┐  │  │
│  │  │  Dashboard  │  │ Workbenches │  │ AI Pipelines │  │  KServe   │  │  │
│  │  │  (RHOAI UI) │  │  (Jupyter)  │  │ (Kubeflow v2)│  │  Serving  │  │  │
│  │  └─────────────┘  └─────────────┘  └──────────────┘  └───────────┘  │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────┐  │  │
│  │  │    Ray      │  │  Training   │  │  TrustyAI    │  │  Model    │  │  │
│  │  │(dist train) │  │  Operator   │  │  (bias/xai)  │  │ Registry  │  │  │
│  │  └─────────────┘  └─────────────┘  └──────────────┘  └───────────┘  │  │
│  │  ┌─────────────┐  ┌─────────────┐                                   │  │
│  │  │   Kueue     │  │   MLflow    │                                   │  │
│  │  │(batch mgmt) │  │ (exp track) │                                   │  │
│  │  └─────────────┘  └─────────────┘                                   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │              Data Science Project  (wave 20)                          │  │
│  │   Namespace: data-science-project  ·  Label: opendatahub.io/dashboard │  │
│  │   Jupyter Notebooks  ·  AI Pipeline runs  ·  KServe endpoints         │  │
│  │   MLflow experiments  ·  Model Registry entries                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ╔═══════════════════════════════════════════════════════════════════════╗  │
│  ║   gitops/opt/*  (conditional — deployed only when enable_gpu = true) ║  │
│  ║                                                                       ║  │
│  ║   ┌─────────────────────────────┐  ┌────────────────────────────┐   ║  │
│  ║   │  Node Feature Discovery     │  │  NVIDIA GPU Operator       │   ║  │
│  ║   │  (openshift-nfd)            │→ │  (nvidia-gpu-operator)     │   ║  │
│  ║   │  Labels GPU worker nodes    │  │  Drivers · Device Plugin   │   ║  │
│  ║   │  waves 0-5                  │  │  DCGM Exporter · wave 10   │   ║  │
│  ║   └─────────────────────────────┘  └────────────────────────────┘   ║  │
│  ╚═══════════════════════════════════════════════════════════════════════╝  │
└─────────────────────────────────────────────────────────────────────────────┘

Bootstrap flow:
  terraform apply
       │
       ▼  Phase 0 — preflight (validate-tfvars.sh + check-cluster-prereqs.sh)
       │  Validates tfvars · OCP 4.19+ · cluster-admin · OperatorHub READY
       │  Warns if GPU nodes detected but enable_gpu = false
       │
       ▼  Phase 1 — Install GitOps operator (oc apply Subscription)
       │
       ▼  Phase 2 — Wait for ArgoCD ready
       │
       ▼  Phase 3 — Grant ArgoCD cluster-admin
       │
       ▼  Phase 4 — Render ApplicationSet → gitops/applicationset.yaml
       │            enable_gpu=false → watches gitops/core/* only
       │            enable_gpu=true  → also adds gitops/opt/nfd + gitops/opt/gpu
       │
       ▼  Phase 5 — Render + apply root Application (ai-ml-root)
       │            Manual sync — nothing deploys until you trigger it
       │
       │  ── Post-terraform manual steps ──────────────────────────────
       │
       ▼  git add gitops/applicationset.yaml && git commit && git push
       │
       ▼  Create vault-bootstrap-creds Secret (before root sync)
       │  oc create namespace vault
       │  oc create secret generic vault-bootstrap-creds -n vault \
       │    --from-literal=RUSTFS_ACCESS_KEY=<access-key> \
       │    --from-literal=RUSTFS_SECRET_KEY=<secret-key>
       │
       ▼  ArgoCD UI: sync ai-ml-root  (one manual click)
                         │
              ┌──────────┘  Root applies the ApplicationSet from git
              │             ApplicationSet discovers configured paths
              │             Creates one child Application per directory
              │             Child Applications auto-sync in wave order:
              │             namespaces(-20) → vault(-10) → vso(-5) → rest(0)
              ▼
      All components installed and self-healing
```

---

## Component Summary

| Component | Namespace | Why It's Needed |
|-----------|-----------|-----------------|
| **OpenShift GitOps** (ArgoCD) | `openshift-gitops` | Bootstrapped by Terraform. Drives the entire stack via GitOps — any change pushed to this repo is automatically applied. Single pane of glass for all sync status. |
| **cert-manager** | `openshift-cert-manager-operator` | Required by KServe for TLS certificate management on model-serving endpoints. Also needed by Kueue and distributed inference workloads. Red Hat supported operator (`stable-v1` channel). |
| **Kueue** | `openshift-kueue-operator` | Batch workload queue management for AI training jobs. Controls resource quotas and job priorities across Ray, PyTorch, and Kubeflow Training workloads. |
| **JobSet** | `openshift-jobset-operator` | Kubernetes JobSet API — required dependency for Kueue and distributed training jobs (multi-node PyTorch, etc.). |
| **Object Storage (RustFS)** | `object-storage` | Open-source S3-compatible object store deployed in-cluster. Credentials are never stored in git — they are synced from HashiCorp Vault via `VaultStaticSecret` CRs. The `s3-credentials` Secret is materialised in `redhat-ods-applications` and picked up by AI Pipelines and MLflow. |
| **OpenShift Pipelines** (Tekton) | `openshift-operators` | CI/CD and ML pipeline orchestration. RHOAI AI Pipelines (Kubeflow v2) uses this as its execution engine for automated model training, evaluation, and promotion workflows. |
| **Red Hat OpenShift AI 3.4** | `redhat-ods-operator` | Core AI/ML platform. Provides: Dashboard, Jupyter Workbenches, AI Pipelines (Kubeflow v2), KServe model serving, Ray distributed training, TrustyAI explainability, MLflow tracking, Model Registry, and Kueue batch management. |
| **Model Registry** | `rhoai-model-registries` | Central repository for registering, versioning, and managing the lifecycle of trained models. Enables model governance, lineage tracking, and sharing across teams before deployment. |
| **MLflow** | `redhat-ods-applications` | Experiment tracking, metric logging, artifact storage, and model versioning. Integrated into RHOAI 3.4 as Technology Preview via the `mlflowoperator` component. |
| **Red Hat SSO** (Keycloak) | `rhsso` | Identity and access management. Provides OIDC/OAuth2 for authenticating users into RHOAI workbenches and the OpenShift console. Supports integration with enterprise LDAP/Active Directory. |
| **HashiCorp Vault** | `vault` | Self-hosted secret store. Deployed first (ApplicationSet wave -10) so credential KV paths are available before dependent components start. A PostSync Job initialises Vault, stores unseal keys in a K8s Secret, and populates `secret/object-storage/*` from a bootstrap Secret the operator creates once (never in git). |
| **Vault Secrets Operator** | `openshift-operators` | Syncs secrets from HashiCorp Vault into Kubernetes Secrets via `VaultStaticSecret` CRs. Deployed at wave -5, after Vault is up. Used to inject RustFS credentials without storing them in git. |
| **User Workload Monitoring** | `openshift-monitoring` | Extends the built-in OpenShift Prometheus to scrape metrics from AI/ML workloads, model servers, and pipeline runs. Required for RHOAI's model-serving metrics and TrustyAI fairness monitoring. |
| **Grafana** | `grafana` | Custom dashboards for GPU utilisation, model inference latency, pipeline throughput, and cluster resource consumption. Connects to OpenShift Thanos Querier. |
| **Data Science Project** | `data-science-project` | Tenant namespace registered in the RHOAI dashboard. Data scientists create notebooks, run pipelines, and deploy models here. RBAC grants access to the `data-scientists` group via RH SSO. |

### Optional components (`gitops/opt/`)

Not deployed by default. Set `enable_gpu = true` in `terraform.tfvars` and re-run `terraform apply` to include them automatically via the ApplicationSet.

| Component | When to enable |
|-----------|---------------|
| **Node Feature Discovery (NFD)** | Required if the cluster has NVIDIA GPU worker nodes. Labels nodes with hardware capabilities so the GPU Operator can target them. Package `nfd`, channel `stable`, from `redhat-operators`. |
| **NVIDIA GPU Operator** | Required for NVIDIA GPU nodes. Installs drivers, the device plugin, DCGM exporter, and configures the container runtime. Deployed after NFD (wave ordering enforced). Package `gpu-operator-certified`, channel `v26.3`, from `certified-operators`. |

---

## Sync Wave Order

There are two levels of wave ordering.

### ApplicationSet level — controls which Application syncs first

The ApplicationSet `sync-wave` annotation on each Application resource determines the order in which ArgoCD creates and syncs the child Applications.

| AppSet Wave | Application | What happens |
|-------------|-------------|--------------|
| `-20` | `namespaces` | All namespaces created before anything else deploys |
| `-10` | `vault` | Vault StatefulSet + Service + Route; PostSync `vault-init` Job initialises Vault, stores unseal keys, enables KV-v2 + K8s auth, populates KV paths |
| `-5` | `vault-secrets-operator` | VSO operator installed; VaultConnection + VaultAuth CRs are ready |
| `0` | all others | cert-manager, Kueue, RHOAI, SSO, object-storage, monitoring, etc. |

### Resource level — controls ordering within each Application

Once an Application starts syncing, its resources apply in ascending resource wave order.

| Wave | What is applied |
|------|----------------|
| `-5` | Namespaces, user workload monitoring ConfigMaps |
| `0` | OperatorGroups (RHOAI, cert-manager, kueue, grafana); VaultConnection + VaultAuth CRs |
| `1` | Subscriptions — cert-manager, Kueue, JobSet, Pipelines, RHOAI, RH SSO, Vault Secrets Operator, Grafana |
| `5` | RustFS Deployment, Service, Route |
| `6` | VaultStaticSecret CRs — materialise `rustfs-credentials` and `s3-credentials` from Vault |
| `10` | DSCInitialization (waits for RHOAI operator to be `Succeeded`) |
| `15` | DataScienceCluster, Keycloak, Grafana instance |
| `20` | MLflow CR instance, Data Science Project RoleBindings |

> **Optional GPU stack** (if enabled): NFD OperatorGroup/Subscription at waves 0-1, NodeFeatureDiscovery CR at wave 5, GPU Operator Subscription at wave 1, ClusterPolicy at wave 10.

---

## Prerequisites

### Local tools

| Tool | Minimum version |
|------|----------------|
| `terraform` | 1.5.0 |
| `oc` | 4.19+ |
| `git` | 2.x |

### Cluster requirements

| Requirement | Minimum |
|-------------|---------|
| OpenShift Container Platform | **4.19** (4.20 for llm-d distributed inference) |
| Worker nodes | 2 (3+ recommended) |
| Allocatable worker CPU | 16 cores across all workers |
| Allocatable worker memory | 64 GiB across all workers |
| GPU nodes | Optional — recommended for ML training workloads |
| Caller permissions | `cluster-admin` |
| OperatorHub | `redhat-operators` and `community-operators` CatalogSources READY |
| Registry access | `registry.redhat.io` and `quay.io` (or a configured mirror registry) |

> **Note:** RHOAI 3.4 is an Early Access release. OCP 4.20 is required only if using distributed inference with llm-d.

Run `bootstrap/scripts/check-cluster-prereqs.sh` to verify all of the above before applying Terraform.

---

## Quick Start

### 1 — Fork and clone this repository

ArgoCD needs a Git URL it can sync from. Fork this repo to your own organisation, then clone it:

```bash
git clone https://github.com/your-org/2-ai-ml-data-layer.git
cd 2-ai-ml-data-layer
```

### 2 — Create your variables file

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars   # fill in kubeconfig_path, cluster_name, gitops_repo_url
```

### 3 — Validate inputs and check cluster prerequisites

Run the two preflight scripts before touching the cluster. They catch misconfigured tfvars and cluster issues early.

```bash
# Check that all required tfvars are filled in
./scripts/validate-tfvars.sh

# Verify OCP version, permissions, OperatorHub, and node capacity
./scripts/check-cluster-prereqs.sh
```

Both scripts are also run automatically as the first step of `terraform apply` (phase 0), so Terraform will abort with a clear error if either check fails.

### 4 — Run bootstrap

```bash
terraform init
terraform plan
terraform apply
```

Terraform will:
1. **Preflight** — validate tfvars and cluster prerequisites
2. Install the OpenShift GitOps operator via `oc apply` (~3 min)
3. Wait for ArgoCD to be ready
4. Grant ArgoCD cluster-wide access
5. Render `gitops/applicationset.yaml` with your repo URL and GPU flag
6. Apply the root Application (`ai-ml-root`) with **manual sync**

### 5 — Commit the rendered ApplicationSet

After `terraform apply` completes, commit the rendered ApplicationSet so ArgoCD can read it:

```bash
# From the repo root
git add gitops/applicationset.yaml
git commit -m "chore: add rendered ApplicationSet"
git push
```

### 6 — Create the Vault bootstrap Secret

Before triggering the root sync, create the Secret that Vault's init Job reads to populate credentials. The `vault` namespace must exist first — create it manually since ArgoCD hasn't run yet.

```bash
oc create namespace vault

oc create secret generic vault-bootstrap-creds -n vault \
  --from-literal=RUSTFS_ACCESS_KEY=<your-access-key> \
  --from-literal=RUSTFS_SECRET_KEY=<your-secret-key>
```

Choose any alphanumeric string for the key/secret (e.g. `rustfsadmin` / `rustfspassword`). These become the RustFS login and the S3 credentials RHOAI uses. **Never commit this Secret to git.**

### 7 — Trigger the root sync

Then open the ArgoCD console and manually sync `ai-ml-root`:

```bash
# Get the ArgoCD console URL
oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}'

# Get the admin password
oc get secret openshift-gitops-cluster -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d && echo
```

In the ArgoCD UI: **Applications → ai-ml-root → Sync → Synchronize**

Or via CLI: `argocd app sync ai-ml-root`

The root Application applies the ApplicationSet, which then creates and auto-syncs all component Applications in wave order (~20–40 min).

### 8 — Monitor progress

```bash
# Watch Applications appear and sync
oc get applications -n openshift-gitops -w

# Check operator install status
oc get csv -A --watch
```

---

## Project Structure

```
2-ai-ml-data-layer/
├── bootstrap/                        # Terraform — run once to seed the cluster
│   ├── scripts/
│   │   ├── validate-tfvars.sh        # Validates terraform.tfvars before apply
│   │   └── check-cluster-prereqs.sh  # Checks OCP version, permissions, capacity
│   ├── versions.tf
│   ├── variables.tf
│   ├── main.tf                       # Preflight + GitOps operator + ApplicationSet
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
└── gitops/
    ├── applicationset.yaml.tpl       # Template — Terraform renders → applicationset.yaml
    ├── applicationset.yaml           # Rendered by Terraform; commit this to git
    ├── root-application.yaml.tpl     # Template — Terraform renders + applies root Application
    ├── core/                         # Main components — auto-deployed by ArgoCD
    │   ├── namespaces/               # All namespaces (wave -5)
    │   ├── cert-manager/             # cert-manager operator (waves 0-1)
    │   ├── kueue/                    # Kueue + JobSet operators (waves 0-1)
    │   ├── object-storage/           # RustFS deployment + VaultStaticSecrets (waves 5-6)
    │   ├── openshift-pipelines/      # Tekton operator (wave 1)
    │   ├── rhoai/                    # RHOAI 3.4 operator + DSC + DSCI (waves 1-15)
    │   ├── mlflow/                   # MLflow CR instance (wave 20)
    │   ├── rhsso/                    # Red Hat SSO + Keycloak (waves 1-15)
    │   ├── vault/                    # HashiCorp Vault (ApplicationSet wave -10)
    │   ├── vault-secrets-operator/   # Vault Secrets Operator (ApplicationSet wave -5)
    │   ├── monitoring/               # Prometheus config + Grafana (waves -5 to 15)
    │   └── data-science-project/     # Tenant namespace + RBAC (wave 20)
    └── opt/                          # Optional components — enabled via enable_gpu tfvar
        ├── nfd/                      # Node Feature Discovery (GPU node labelling)
        └── gpu/                      # NVIDIA GPU Operator + ClusterPolicy
```

---

## Adding a New Component

1. Create a new directory under `gitops/core/<component-name>/`
2. Add a `kustomization.yaml` referencing your manifests
3. Add sync-wave annotations to control ordering
4. Commit and push — ArgoCD picks up the new directory automatically via the git generator

No Terraform changes are needed.

---

## Enabling KServe with Service Mesh (already enabled in this config)

KServe is enabled by default in this configuration (`managementState: Managed`) and RHOAI manages the Service Mesh control plane via the DSCInitialization CR (`serviceMesh.managementState: Managed`). If your cluster already has an existing Service Mesh, change `serviceMesh.managementState` to `Unmanaged` in `gitops/core/rhoai/dsc-initialization.yaml` and set `controlPlane` to point to your existing SMCP.

---

## Enabling Optional Components

### GPU support — Node Feature Discovery + NVIDIA GPU Operator

Required only when the cluster has NVIDIA GPU worker nodes. The manifests live in `gitops/opt/nfd` and `gitops/opt/gpu`; no file copying is needed.

**Enable via Terraform flag:**

```hcl
# bootstrap/terraform.tfvars
enable_gpu = true
```

Then re-apply:

```bash
terraform apply
```

Terraform re-renders the ApplicationSet to also watch `gitops/opt/nfd` and `gitops/opt/gpu`. ArgoCD picks up both directories automatically on the next sync. NFD runs at waves 0–5 and labels GPU nodes; the GPU ClusterPolicy runs at wave 10 once nodes are labelled.

> The `check-cluster-prereqs.sh` script will warn if it detects GPU-capable nodes but `enable_gpu` is not set to `true`.

### Object storage — RustFS + Vault setup

`gitops/core/vault/` deploys a single-node HashiCorp Vault and a PostSync Job that automatically initialises it. `gitops/core/object-storage/` then deploys RustFS and uses the **Vault Secrets Operator** to materialise credentials — no secrets are stored in git.

The same RustFS key pair is used for both paths:
- `secret/object-storage/rustfs` — used by the RustFS server pod
- `secret/object-storage/s3-credentials` — used by RHOAI AI Pipelines and MLflow to connect to RustFS as an S3 endpoint

#### Step 1 — Create the vault namespace (if not yet created by ArgoCD)

```bash
oc create namespace vault
```

#### Step 2 — Create the bootstrap Secret

This is the only secret you ever touch manually. It provides the RustFS credentials the init Job writes into Vault KV. Never commit this to git.

```bash
oc create secret generic vault-bootstrap-creds -n vault \
  --from-literal=RUSTFS_ACCESS_KEY=<your-access-key> \
  --from-literal=RUSTFS_SECRET_KEY=<your-secret-key>
```

Choose any alphanumeric string for the key and secret (e.g. `rustfsadmin` / `rustfspassword`). These become the login for the RustFS console and the S3 credentials RHOAI uses.

#### Step 3 — Push to git and let ArgoCD sync

ArgoCD syncs in this order (enforced by ApplicationSet sync waves):

| Wave | Application | What happens |
|------|-------------|--------------|
| -20 | `namespaces` | Creates the `vault`, `object-storage`, `redhat-ods-applications` namespaces |
| -10 | `vault` | Deploys Vault StatefulSet; PostSync `vault-init` Job runs automatically |
| -5 | `vault-secrets-operator` | Installs the VSO operator |
| 0 | `object-storage` | Deploys RustFS; `VaultStaticSecret` CRs materialise credentials from Vault |
| 0 | everything else | RHOAI, MLflow, RHSSO, monitoring, etc. |

The `vault-init` Job (PostSync hook) does the following automatically on each sync:
1. Waits for the Vault API to respond
2. Initialises Vault on first run; on subsequent runs reads the existing unseal key
3. Stores unseal key + root token in `vault-unseal-keys` Secret in the `vault` namespace
4. Unseals Vault if sealed
5. Enables KV-v2 at `secret/`
6. Enables Kubernetes auth; creates `object-storage` and `rhoai` roles
7. Writes `secret/object-storage/rustfs` and `secret/object-storage/s3-credentials` from the bootstrap Secret

#### Step 4 — Create the S3 bucket in RustFS

After RustFS is running (object-storage Application synced), create the bucket ArgoCD does not create it for you:

```bash
# Get the RustFS route URL
RUSTFS_URL=$(oc get route rustfs -n object-storage -o jsonpath='https://{.spec.host}')

# Read the access key you set in Step 2
export AWS_ACCESS_KEY_ID=<your-access-key>
export AWS_SECRET_ACCESS_KEY=<your-secret-key>

aws s3 mb s3://rhoai-models --endpoint-url "$RUSTFS_URL"
```

The `s3-credentials` Secret is then live in `redhat-ods-applications` and automatically picked up by AI Pipelines and MLflow.

### Feature Store (Feast)
Set `feastoperator.managementState: Managed` in `gitops/core/rhoai/data-science-cluster.yaml`.

### Llama Stack (RAG workloads)
1. Install the Red Hat OpenShift Service Mesh 3.x operator
2. Set `llamastackoperator.managementState: Managed` in the DataScienceCluster

### MLflow Production Backend
Edit `gitops/core/mlflow/mlflow.yaml` and replace:
- `backendStoreUri` with a PostgreSQL connection string
- `artifactsDestination` with the S3 URI (`s3://my-ocp-ai-artifacts/mlflow`)

---

## Security Notes

- `bootstrap/terraform.tfvars` is gitignored — never commit it (contains kubeconfig path and optional git token)
- `bootstrap/.rendered/` is gitignored — contains the rendered ApplicationSet with the repo URL
- The ArgoCD admin account should be disabled post-setup in favour of OpenShift OAuth (configured via RH SSO)
- The `data-scientists` group in the Data Science Project RoleBinding is provisioned from LDAP/SSO via Red Hat SSO group sync
- MLflow is Technology Preview in RHOAI 3.4 — do not use for production model serving
