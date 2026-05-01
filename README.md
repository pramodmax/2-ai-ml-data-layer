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
│        │ (wave -5)  │  │  (waves 0 → 1)   │  │  (waves -5→15)   ││        │
│        │            │  │                  │  │                   ││        │
│        │cert-mgr-op │  │ cert-manager     │  │ User Workload     ││        │
│        │kueue-op    │  │ Kueue + JobSet   │  │ Monitoring        ││        │
│        │jobset-op   │  │ OCP Pipelines    │  │ (Prometheus)      ││        │
│        │rhsso       │  │ Red Hat SSO      │  │                   ││        │
│        │ext-secrets │  │ Ext Secrets Op   │  │ Grafana Operator  ││        │
│        │grafana     │  └──────────────────┘  │ (ML dashboards)  ││        │
│        │rhoai-regs  │                         └───────────────────┘│        │
│        │data-sci-   │  ┌──────────────────────────────────────────┐│        │
│        │ project    │  │  Object Storage (wave 5)                 ││        │
│        └────────────┘  │  RustFS (S3-compatible, in-cluster)      ││        │
│                        │  s3-credentials → redhat-ods-applications││        │
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
       ▼  ArgoCD UI: sync ai-ml-root  (one manual click)
                         │
              ┌──────────┘  Root applies the ApplicationSet from git
              │             ApplicationSet discovers configured paths
              │             Creates one child Application per directory
              │             Child Applications auto-sync in wave order
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
| **Object Storage (RustFS)** | `object-storage` | Open-source S3-compatible object store deployed in-cluster. Provides artifact storage for AI Pipelines and MLflow without any cloud dependency. The `s3-credentials` Secret is created in `redhat-ods-applications` pointing to the in-cluster RustFS endpoint. |
| **OpenShift Pipelines** (Tekton) | `openshift-operators` | CI/CD and ML pipeline orchestration. RHOAI AI Pipelines (Kubeflow v2) uses this as its execution engine for automated model training, evaluation, and promotion workflows. |
| **Red Hat OpenShift AI 3.4** | `redhat-ods-operator` | Core AI/ML platform. Provides: Dashboard, Jupyter Workbenches, AI Pipelines (Kubeflow v2), KServe model serving, Ray distributed training, TrustyAI explainability, MLflow tracking, Model Registry, and Kueue batch management. |
| **Model Registry** | `rhoai-model-registries` | Central repository for registering, versioning, and managing the lifecycle of trained models. Enables model governance, lineage tracking, and sharing across teams before deployment. |
| **MLflow** | `redhat-ods-applications` | Experiment tracking, metric logging, artifact storage, and model versioning. Integrated into RHOAI 3.4 as Technology Preview via the `mlflowoperator` component. |
| **Red Hat SSO** (Keycloak) | `rhsso` | Identity and access management. Provides OIDC/OAuth2 for authenticating users into RHOAI workbenches and the OpenShift console. Supports integration with enterprise LDAP/Active Directory. |
| **External Secrets Operator** | `external-secrets` | Optional. Bridges external secret stores (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault) with Kubernetes Secrets. Not required for object storage — RustFS uses a static in-cluster Secret. |
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

ArgoCD applies resources in ascending wave order. This ensures dependencies (namespaces before operators, operators before CRs) are always satisfied.

| Wave | What is applied |
|------|----------------|
| `-5` | All namespaces, user workload monitoring ConfigMaps |
| `0` | OperatorGroups (RHOAI, cert-manager, kueue, jobset, ext-secrets, grafana) |
| `1` | Subscriptions — cert-manager, Kueue, JobSet, Pipelines, RHOAI, RH SSO, Ext Secrets, Grafana |
| `5` | RustFS Deployment, Service, Route, credentials Secret |
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

### 5 — Commit the rendered ApplicationSet and trigger the root sync

After `terraform apply` completes, commit the rendered ApplicationSet so ArgoCD can read it:

```bash
# From the repo root
git add gitops/applicationset.yaml
git commit -m "chore: add rendered ApplicationSet"
git push
```

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

### 6 — Monitor progress

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
    │   ├── object-storage/           # RustFS deployment + s3-credentials Secret (wave 5)
    │   ├── openshift-pipelines/      # Tekton operator (wave 1)
    │   ├── rhoai/                    # RHOAI 3.4 operator + DSC + DSCI (waves 1-15)
    │   ├── mlflow/                   # MLflow CR instance (wave 20)
    │   ├── rhsso/                    # Red Hat SSO + Keycloak (waves 1-15)
    │   ├── external-secrets/         # External Secrets Operator (wave 1)
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

### Object storage — RustFS setup

`gitops/core/object-storage/` deploys RustFS, an open-source S3-compatible object store, directly in the cluster. No cloud account or external secret store is required.

**Default credentials** are set in `gitops/core/object-storage/rustfs-secret.yaml`. Change them before going to production:

```yaml
# gitops/core/object-storage/rustfs-secret.yaml
stringData:
  access-key: "your-access-key"
  secret-key: "your-secret-key"
```

Update `gitops/core/object-storage/rhoai-s3-credentials.yaml` with the same values so AI Pipelines and MLflow can authenticate:

```yaml
stringData:
  AWS_ACCESS_KEY_ID: "your-access-key"
  AWS_SECRET_ACCESS_KEY: "your-secret-key"
  AWS_S3_BUCKET: "rhoai-models"
  AWS_S3_ENDPOINT_URL: "http://rustfs.object-storage.svc.cluster.local:9000"
```

**Create the initial bucket** after RustFS is running (get the Route URL from ArgoCD or `oc`):

```bash
RUSTFS_URL=$(oc get route rustfs -n object-storage -o jsonpath='https://{.spec.host}')
aws s3 mb s3://rhoai-models --endpoint-url "$RUSTFS_URL"
```

The `s3-credentials` Secret is created in `redhat-ods-applications` at sync wave 15 and is automatically picked up by AI Pipelines and MLflow.

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
