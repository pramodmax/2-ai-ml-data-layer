# AI/ML Data Layer — GitOps Bootstrap

Terraform bootstrap + GitOps manifests for deploying a production-ready AI/ML platform on Red Hat OpenShift. Terraform installs OpenShift GitOps (ArgoCD) and registers one ApplicationSet; from that point ArgoCD owns the full stack.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster (OCP 4.16)                         │
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
│          ┌──────────────────┼───────────────────────────────┐              │
│          │                  │   Sync Wave Order             │              │
│          ▼                  ▼                               ▼              │
│  ┌──────────────┐  ┌─────────────────────┐  ┌──────────────────────────┐  │
│  │  Namespaces  │  │  Platform Operators  │  │       Monitoring         │  │
│  │  (wave  -5)  │  │    (waves 0 → 1)     │  │     (waves -5 → 15)      │  │
│  │              │  │                      │  │                          │  │
│  │ redhat-ods-  │  │ ┌──────────────────┐ │  │ ┌──────────────────────┐ │  │
│  │   operator   │  │ │OpenShift Pipelines│ │  │ │  User Workload       │ │  │
│  │    rhsso     │  │ └──────────────────┘ │  │ │  Monitoring          │ │  │
│  │  external-   │  │ ┌──────────────────┐ │  │ │  (Prometheus)        │ │  │
│  │   secrets    │  │ │   Red Hat SSO    │ │  │ └──────────────────────┘ │  │
│  │    grafana   │  │ └──────────────────┘ │  │ ┌──────────────────────┐ │  │
│  │  data-sci-   │  │ ┌──────────────────┐ │  │ │   Grafana Operator   │ │  │
│  │   project    │  │ │ External Secrets  │ │  │ │   (custom dashboards)│ │  │
│  └──────────────┘  │ └──────────────────┘ │  │ └──────────────────────┘ │  │
│                    └─────────────────────-┘  └──────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │              Red Hat OpenShift AI 3.4   (waves 1 → 15)               │  │
│  │                                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌───────────┐  │  │
│  │  │  Dashboard  │  │ Workbenches │  │  DS Pipelines│  │ ModelMesh │  │  │
│  │  │  (RHOAI UI) │  │  (Jupyter)  │  │  (Kubeflow)  │  │  Serving  │  │  │
│  │  └─────────────┘  └─────────────┘  └──────────────┘  └───────────┘  │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐                 │  │
│  │  │  CodeFlare  │  │     Ray     │  │   TrustyAI   │                 │  │
│  │  │  (job mgmt) │  │ (dist train)│  │  (bias/xai)  │                 │  │
│  │  └─────────────┘  └─────────────┘  └──────────────┘                 │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │              Data Science Project  (wave 20)                          │  │
│  │                                                                       │  │
│  │   Namespace: data-science-project  ·  Label: opendatahub.io/dashboard│  │
│  │   Jupyter Notebooks  ·  DS Pipelines runs  ·  ModelMesh endpoints    │  │
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
| **OpenShift GitOps** (ArgoCD) | `openshift-gitops` | Bootstrapped by Terraform. Drives the entire stack via GitOps — any change pushed to this repo is automatically applied to the cluster. Single pane of glass for all sync status. |
| **OpenShift Pipelines** (Tekton) | `openshift-operators` | CI/CD and ML pipeline orchestration. RHOAI Data Science Pipelines (Kubeflow v2) uses this as its execution engine for automated model training, evaluation, and promotion workflows. |
| **Red Hat OpenShift AI 3.4** | `redhat-ods-operator` | Core AI/ML platform. Provides the RHOAI Dashboard, Jupyter Workbenches, Data Science Pipelines, ModelMesh Serving, distributed training via Ray/CodeFlare, and model explainability via TrustyAI. |
| **Red Hat SSO** (Keycloak) | `rhsso` | Identity and access management. Provides OIDC/OAuth2 for authenticating users into RHOAI workbenches and the OpenShift console. Supports integration with enterprise LDAP, Active Directory, and social identity providers. |
| **External Secrets Operator** | `external-secrets` | Bridges external secret stores (AWS Secrets Manager, HashiCorp Vault, Azure Key Vault) with Kubernetes Secrets. Keeps credentials out of git and allows workloads to consume secrets as native Kubernetes objects without hardcoding them. |
| **User Workload Monitoring** | `openshift-monitoring` | Extends the built-in OpenShift Prometheus to scrape metrics from AI/ML workloads, model servers, and pipeline runs. Required for RHOAI's built-in model-serving metrics and TrustyAI fairness monitoring. |
| **Grafana** | `grafana` | Custom dashboards for GPU utilisation, model inference latency, pipeline throughput, and cluster resource consumption. Connects to the OpenShift Thanos Querier as its data source. |
| **Data Science Project** | `data-science-project` | Tenant namespace registered in the RHOAI dashboard. Data scientists create notebooks, run pipelines, and deploy models within this project. RBAC grants access to the `data-scientists` group via RH SSO. |

---

## Sync Wave Order

ArgoCD applies resources in ascending wave order within each Application. This ensures dependencies (namespaces before operators, operators before CRs) are always satisfied.

| Wave | What is applied |
|------|----------------|
| `-5` | All namespaces, user workload monitoring ConfigMaps |
| `0` | OperatorGroups |
| `1` | Subscriptions (operator installations begin) |
| `10` | DSCInitialization (waits for RHOAI operator to be `Succeeded`) |
| `15` | DataScienceCluster, Keycloak, Grafana instance |
| `20` | Data Science Project RoleBindings |

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| `terraform` | 1.5.0 |
| `oc` | 4.14+ |
| `git` | 2.x |

The target cluster must be running OCP 4.16+ with internet access to `registry.redhat.io` and `quay.io` (or a configured mirror registry).

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

ArgoCD then takes over and installs all remaining components in sync-wave order (~15–30 min depending on pull rate).

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
│   ├── versions.tf                   # Provider version pins
│   ├── variables.tf                  # Input variables
│   ├── main.tf                       # GitOps operator + ApplicationSet bootstrap
│   ├── outputs.tf                    # ArgoCD URL and access commands
│   └── terraform.tfvars.example      # Copy to terraform.tfvars and fill in
│
└── gitops/                           # ArgoCD manages everything in here
    ├── applicationset.yaml.tpl       # Template rendered by Terraform bootstrap
    └── components/                   # One directory = one ArgoCD Application
        ├── namespaces/               # All namespaces (wave -5)
        ├── openshift-pipelines/      # Tekton operator (wave 1)
        ├── rhoai/                    # RHOAI 3.4 operator + DSC + DSCI (waves 1-15)
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

## Enabling KServe (Single-Model Serving)

KServe is disabled by default to avoid the Service Mesh and Serverless dependencies. To enable it:

1. Add `gitops/components/service-mesh/` with the OpenShift Service Mesh operator subscription and `ServiceMeshControlPlane` CR
2. Add `gitops/components/serverless/` with the OpenShift Serverless operator subscription and `KnativeServing` CR
3. Update `gitops/components/rhoai/dsc-initialization.yaml` — set `serviceMesh.managementState: Managed`
4. Update `gitops/components/rhoai/data-science-cluster.yaml` — set `kserve.managementState: Managed`

---

## Security Notes

- `bootstrap/terraform.tfvars` is gitignored — never commit it (contains kubeconfig path and optional git token)
- `bootstrap/.rendered/` is gitignored — contains the rendered ApplicationSet with the repo URL
- The ArgoCD admin account should be disabled post-setup in favour of OpenShift OAuth (configured via RH SSO)
- The `data-scientists` group in the Data Science Project RoleBinding is provisioned from LDAP/SSO via Red Hat SSO group sync
