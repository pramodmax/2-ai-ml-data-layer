apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ai-ml-data-layer
  namespace: openshift-gitops
spec:
  generators:
  - git:
      repoURL: ${gitops_repo_url}
      revision: ${gitops_repo_revision}
      directories:
      - path: ${gitops_components_path}/*
  template:
    metadata:
      name: "{{path.basename}}"
      namespace: openshift-gitops
      annotations:
        argocd.argoproj.io/managed-by: openshift-gitops
    spec:
      project: default
      source:
        repoURL: ${gitops_repo_url}
        targetRevision: ${gitops_repo_revision}
        path: "{{path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: openshift-gitops
      syncPolicy:
        automated:
          prune: false
          selfHeal: true
        syncOptions:
        - CreateNamespace=false
        - ServerSideApply=true
        - RespectIgnoreDifferences=true
        retry:
          limit: 10
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 5m
