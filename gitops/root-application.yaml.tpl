apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ai-ml-root
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: ${gitops_repo_url}
    targetRevision: ${gitops_repo_revision}
    path: gitops
    directory:
      include: "applicationset.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    syncOptions:
    - RespectIgnoreDifferences=true
