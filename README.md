# cognidispatch-helm

GitOps Helm chart repository for **CogniDispatch** — managed by ArgoCD.

## Branch Strategy

| Branch | Environment | Tracked By |
|---|---|---|
| `production` | Production | ArgoCD prod apps |
| `dev` | Development | ArgoCD dev apps |

## Structure

```
cognidispatch-helm/
├── Chart.yaml              # Helm chart metadata
├── values.yaml             # Base/default values
├── values-dev.yaml         # Dev environment overrides
├── values-prod.yaml        # Production environment overrides
├── templates/              # Kubernetes manifests
├── microservices/          # Per-service image tag files (auto-updated by CI)
│   ├── auth-service/
│   │   ├── values-dev.yaml    ← updated when dev branch pipeline runs
│   │   └── values-prod.yaml   ← updated when production branch pipeline runs
│   ├── vendor-service/
│   ├── ai-service/
│   ├── admin-service/
│   ├── dispatch-service/
│   ├── payment-service/
│   └── frontend/
├── argocd-apps/            # ArgoCD Application CRDs (dev)
└── argocd-apps-prod/       # ArgoCD Application CRDs (production)
```

## How it works

1. Developer pushes to `dev` or `production` branch of a service repo
2. CI pipeline builds the Docker image and pushes to ACR
3. CI pipeline calls `_update_helm.yml` reusable workflow
4. The workflow updates `microservices/<service>/values-<env>.yaml` in this repo
5. ArgoCD detects the change and syncs the deployment
