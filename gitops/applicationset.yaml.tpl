apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ai-ml-data-layer
  namespace: openshift-gitops
spec:
  goTemplate: true
  generators:
  - git:
      repoURL: ${gitops_repo_url}
      revision: ${gitops_repo_revision}
      directories:
      - path: ${gitops_components_path}/*
%{ if enable_gpu ~}
      - path: gitops/opt/nfd
      - path: gitops/opt/gpu
%{ endif ~}
  template:
    metadata:
      name: '{{.path.basename}}'
      namespace: openshift-gitops
      annotations:
        argocd.argoproj.io/managed-by: openshift-gitops
        argocd.argoproj.io/sync-wave: '{{ if eq .path.basename "namespaces" }}-20{{ else if eq .path.basename "vault" }}-10{{ else if eq .path.basename "vault-secrets-operator" }}-5{{ else }}0{{ end }}'
    spec:
      project: default
      source:
        repoURL: ${gitops_repo_url}
        targetRevision: ${gitops_repo_revision}
        path: '{{.path.path}}'
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
