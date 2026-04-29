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
│        ┌────────────────────┼────────────────────────────────┐             │
│        │                   │                                 │             │
│        ▼                   ▼                                 ▼             │
│  ┌───────────┐  ┌─────────────────────┐  ┌───────────────────────────┐   │
│  │Namespaces │  │  Platform Operators  │  │        Monitoring         │   │
│  │ (wave -5) │  │    (waves 0 → 1)     │  │      (waves -5 → 15)      │   │
│  │           │  │                     │  │                           │   │
│  │cert-mgr-  │  │ ┌─────────────────┐ │  │ ┌─────────────────────┐  │   │
│  │ operator  │  │ │  cert-manager   │ │  │ │  User Workload      │  │   │
│  │kueue-op   │  │ └─────────────────┘ │  │ │  Monitoring         │  │   │
│  │jobset-op  │  │ ┌─────────────────┐ │  │ │  (Prometheus)       │  │   │
│  │rhsso      │  │ │ Kueue + JobSet  │ │  │ └─────────────────────┘  │   │
│  │ext-secret │  │ └─────────────────┘ │  │ ┌─────────────────────┐  │   │
│  │grafana    │  │ ┌─────────────────┐ │  │ │  Grafana Operator   │  │   │
│  │rhoai-     │  │ │  OCP Pipelines  │ │  │ │  (ML dashboards)    │  │   │
│  │model-reg  │  │ └─────────────────┘ │  │ └─────────────────────┘  │   │
│  │data-sci-  │  │ ┌─────────────────┐ │  └───────────────────────────┘   │
│  │ project   │  │ │  Red Hat SSO    │ │                                   │
│  └───────────┘  │ └─────────────────┘ │                                   │
│                 │ ┌─────────────────┐ │                                   │
│                 │ │ Ext Secrets Op  │ │                                   │
│                 │ └─────────────────┘ │                                   │
│                 └─────────────────────┘                                   │
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
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐                 │  │
│  │  │   Kueue     │  │   MLflow    │  │  Feast Store │                 │  │
│  │  │(batch mgmt) │  │ (exp track) │  │  (optional)  │                 │  │
│  │  └─────────────┘  └─────────────┘  └──────────────┘                 │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │              Data Science Project  (wave 20)                          │  │
│  │   Namespace: data-science-project  ·  Label: opendatahub.io/dashboard │  │
│  │   Jupyter Notebooks  ·  AI Pipeline runs  ·  KServe endpoints         │  │
│  │   MLflow experiments  ·  Model Registry entries                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘

Bootstrap flow:
  terraform apply  →  GitOps operator  →  ArgoCD ready  →  ApplicationSet
                                                              │
                      ┌────────────────────────────────────── ┘
                      │  Discovers gitops/components/*
                      │  Creates one Application per directory
                      │  Sync waves sequence the install order
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
| **OpenShift Pipelines** (Tekton) | `openshift-operators` | CI/CD and ML pipeline orchestration. RHOAI AI Pipelines (Kubeflow v2) uses this as its execution engine for automated model training, evaluation, and promotion workflows. |
| **Red Hat OpenShift AI 3.4** | `redhat-ods-operator` | Core AI/ML platform. Provides: Dashboard, Jupyter Workbenches, AI Pipelines (Kubeflow v2), KServe model serving, Ray distributed training, TrustyAI explainability, MLflow tracking, Model Registry, and Kueue batch management. |
| **Model Registry** | `rhoai-model-registries` | Central repository for registering, versioning, and managing the lifecycle of trained models. Enables model governance, lineage tracking, and sharing across teams before deployment. |
| **MLflow** | `redhat-ods-applications` | Experiment tracking, metric logging, artifact storage, and model versioning. Integrated into RHOAI 3.4 as Technology Preview via the `mlflowoperator` component. |
| **Red Hat SSO** (Keycloak) | `rhsso` | Identity and access management. Provides OIDC/OAuth2 for authenticating users into RHOAI workbenches and the OpenShift console. Supports integration with enterprise LDAP/Active Directory. |
| **External Secrets Operator** | `external-secrets` | Bridges external secret stores (AWS Secrets Manager, HashiCorp Vault, Azure Key Vault) with Kubernetes Secrets. Keeps credentials out of git. |
| **User Workload Monitoring** | `openshift-monitoring` | Extends the built-in OpenShift Prometheus to scrape metrics from AI/ML workloads, model servers, and pipeline runs. Required for RHOAI's model-serving metrics and TrustyAI fairness monitoring. |
| **Grafana** | `grafana` | Custom dashboards for GPU utilisation, model inference latency, pipeline throughput, and cluster resource consumption. Connects to OpenShift Thanos Querier. |
| **Data Science Project** | `data-science-project` | Tenant namespace registered in the RHOAI dashboard. Data scientists create notebooks, run pipelines, and deploy models here. RBAC grants access to the `data-scientists` group via RH SSO. |

---

## Sync Wave Order

ArgoCD applies resources in ascending wave order. This ensures dependencies (namespaces before operators, operators before CRs) are always satisfied.

| Wave | What is applied |
|------|----------------|
| `-5` | All namespaces, user workload monitoring ConfigMaps |
| `0` | OperatorGroups (RHOAI, cert-manager, kueue, jobset, ext-secrets, grafana) |
| `1` | Subscriptions — cert-manager, Kueue, JobSet, Pipelines, RHOAI, RH SSO, Ext Secrets, Grafana |
| `10` | DSCInitialization (waits for RHOAI operator to be `Succeeded`) |
| `15` | DataScienceCluster, Keycloak, Grafana instance |
| `20` | MLflow CR instance, Data Science Project RoleBindings |

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| `terraform` | 1.5.0 |
| `oc` | 4.19+ |
| `git` | 2.x |

The target cluster must be running **OCP 4.19 or 4.20** with internet access to `registry.redhat.io` and `quay.io` (or a configured mirror registry).

> **Note:** RHOAI 3.4 is an Early Access release. OCP 4.20 is required only if using distributed inference with llm-d.

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

### 3 — Run bootstrap

```bash
terraform init
terraform plan
terraform apply
```

Terraform will:
1. Install the OpenShift GitOps operator (~3 min)
2. Wait for ArgoCD to be ready
3. Grant ArgoCD cluster-wide access
4. Apply the ApplicationSet pointing at your fork

ArgoCD then takes over and installs all remaining components in sync-wave order (~20–40 min depending on pull rate).

### 4 — Monitor progress

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
│   ├── versions.tf
│   ├── variables.tf
│   ├── main.tf                       # GitOps operator + ApplicationSet bootstrap
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
└── gitops/                           # ArgoCD manages everything in here
    ├── applicationset.yaml.tpl       # Template rendered by Terraform bootstrap
    └── components/                   # One directory = one ArgoCD Application
        ├── namespaces/               # All namespaces (wave -5)
        ├── cert-manager/             # cert-manager operator (waves 0-1)
        ├── kueue/                    # Kueue + JobSet operators (waves 0-1)
        ├── openshift-pipelines/      # Tekton operator (wave 1)
        ├── rhoai/                    # RHOAI 3.4 operator + DSC + DSCI (waves 1-15)
        ├── mlflow/                   # MLflow CR instance (wave 20)
        ├── rhsso/                    # Red Hat SSO + Keycloak (waves 1-15)
        ├── external-secrets/         # External Secrets Operator (wave 1)
        ├── monitoring/               # Prometheus config + Grafana (waves -5 to 15)
        └── data-science-project/     # Tenant namespace + RBAC (wave 20)
```

---

## Adding a New Component

1. Create a new directory under `gitops/components/<component-name>/`
2. Add a `kustomization.yaml` referencing your manifests
3. Add sync-wave annotations to control ordering
4. Commit and push — ArgoCD picks up the new directory automatically via the git generator

No Terraform changes are needed.

---

## Enabling KServe with Service Mesh (already enabled in this config)

KServe is enabled by default in this configuration (`managementState: Managed`) and RHOAI manages the Service Mesh control plane via the DSCInitialization CR (`serviceMesh.managementState: Managed`). If your cluster already has an existing Service Mesh, change `serviceMesh.managementState` to `Unmanaged` in `gitops/components/rhoai/dsc-initialization.yaml` and set `controlPlane` to point to your existing SMCP.

---

## Enabling Optional Components

### Feature Store (Feast)
Set `feastoperator.managementState: Managed` in `gitops/components/rhoai/data-science-cluster.yaml`.

### Llama Stack (RAG workloads)
1. Install the Red Hat OpenShift Service Mesh 3.x operator
2. Set `llamastackoperator.managementState: Managed` in the DataScienceCluster

### MLflow Production Backend
Edit `gitops/components/mlflow/mlflow.yaml` and replace:
- `backendStoreUri` with a PostgreSQL connection string
- `artifactsDestination` with an S3 or OBC URI

---

## Security Notes

- `bootstrap/terraform.tfvars` is gitignored — never commit it (contains kubeconfig path and optional git token)
- `bootstrap/.rendered/` is gitignored — contains the rendered ApplicationSet with the repo URL
- The ArgoCD admin account should be disabled post-setup in favour of OpenShift OAuth (configured via RH SSO)
- The `data-scientists` group in the Data Science Project RoleBinding is provisioned from LDAP/SSO via Red Hat SSO group sync
- MLflow is Technology Preview in RHOAI 3.4 — do not use for production model serving
