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
│        └────────────┘  │  AWS S3 via External Secrets Operator    ││        │
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
       │  check-cluster-prereqs.sh warns if GPU nodes detected but enable_gpu = false
       │
       ▼  Phase 1 — GitOps operator subscription
       │
       ▼  Phase 2 — wait for ArgoCD ready
       │
       ▼  Phase 3 — grant ArgoCD cluster-admin
       │
       ▼  Phase 4 — render ApplicationSet from template
       │            enable_gpu=false → watches gitops/core/* only
       │            enable_gpu=true  → also adds gitops/opt/nfd + gitops/opt/gpu
       │
       ▼  Phase 5 — apply ApplicationSet
                         │
              ┌──────────┘  Discovers configured paths
              │             Creates one Application per directory
              │             Sync waves sequence the install order
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
| **Object Storage (S3)** | `redhat-ods-applications` | S3 credentials injected via External Secrets Operator from AWS Secrets Manager. Required by AI Pipelines for artifact storage and by MLflow for experiment artifacts. Uses native AWS S3 — no in-cluster object store operator needed on AWS IPI. |
| **OpenShift Pipelines** (Tekton) | `openshift-operators` | CI/CD and ML pipeline orchestration. RHOAI AI Pipelines (Kubeflow v2) uses this as its execution engine for automated model training, evaluation, and promotion workflows. |
| **Red Hat OpenShift AI 3.4** | `redhat-ods-operator` | Core AI/ML platform. Provides: Dashboard, Jupyter Workbenches, AI Pipelines (Kubeflow v2), KServe model serving, Ray distributed training, TrustyAI explainability, MLflow tracking, Model Registry, and Kueue batch management. |
| **Model Registry** | `rhoai-model-registries` | Central repository for registering, versioning, and managing the lifecycle of trained models. Enables model governance, lineage tracking, and sharing across teams before deployment. |
| **MLflow** | `redhat-ods-applications` | Experiment tracking, metric logging, artifact storage, and model versioning. Integrated into RHOAI 3.4 as Technology Preview via the `mlflowoperator` component. |
| **Red Hat SSO** (Keycloak) | `rhsso` | Identity and access management. Provides OIDC/OAuth2 for authenticating users into RHOAI workbenches and the OpenShift console. Supports integration with enterprise LDAP/Active Directory. |
| **External Secrets Operator** | `external-secrets` | Bridges external secret stores (AWS Secrets Manager, HashiCorp Vault, Azure Key Vault) with Kubernetes Secrets. Keeps credentials out of git. |
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
| `5` | ClusterSecretStore (ESO → AWS Secrets Manager), S3 ExternalSecret |
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
2. Install the OpenShift GitOps operator (~3 min)
3. Wait for ArgoCD to be ready
4. Grant ArgoCD cluster-wide access
5. Apply the ApplicationSet pointing at your fork

ArgoCD then takes over and installs all remaining components in sync-wave order (~20–40 min depending on pull rate).

### 5 — Monitor progress

```bash
# Watch applications sync
oc get applications -n openshift-gitops -w

# Check operator install status
oc get csv -A --watch

# Access ArgoCD console
oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}{"\n"}'

# Get ArgoCD admin password
oc get secret openshift-gitops-cluster -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d && echo
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
    ├── applicationset.yaml.tpl       # Template rendered by Terraform bootstrap
    ├── core/                         # Main components — auto-deployed by ArgoCD
    │   ├── namespaces/               # All namespaces (wave -5)
    │   ├── cert-manager/             # cert-manager operator (waves 0-1)
    │   ├── kueue/                    # Kueue + JobSet operators (waves 0-1)
    │   ├── object-storage/           # AWS S3 ClusterSecretStore + ExternalSecret (wave 5)
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

### S3 object storage — pre-requisite setup

`gitops/core/object-storage/` is auto-deployed and configures AWS S3 access. Before ArgoCD syncs it you must:

1. **Create an S3 bucket** in AWS (same region as your cluster):
   ```bash
   aws s3 mb s3://my-ocp-ai-artifacts --region us-east-1
   ```

2. **Store credentials in AWS Secrets Manager:**
   ```bash
   aws secretsmanager create-secret \
     --name "ocp-ai/s3-credentials" \
     --region us-east-1 \
     --secret-string '{
       "accessKeyId":     "AKIA...",
       "secretAccessKey": "...",
       "bucketName":      "my-ocp-ai-artifacts",
       "region":          "us-east-1"
     }'
   ```

3. **Update the region** in `gitops/core/object-storage/cluster-secret-store.yaml` if your cluster is not in `us-east-1`.

The `s3-credentials` Kubernetes Secret is then created in `redhat-ods-applications` and referenced by AI Pipelines and MLflow.

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
