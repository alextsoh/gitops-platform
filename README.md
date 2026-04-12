# GITOPS-PLATFORM
## Overview

This repository uses GitHub Actions workflows to automate testing, building, and deploying container images via Kustomize overlays and spin up a AKS cluster via terraform.

---

## Workflows

### 1. Test Workflow (`test.yml`)

Triggers on tag push `v*.*.*`. Runs `api-test` and `client-test` jobs in parallel — lint, tests, and build validation. Blocks `image-ci` via `workflow_run` on failure.

---

### 2. Build and Push (`build.yml`)

Triggered by:
- `push` to `main` with changes in `App/api-node/**` or `App/client-react/**` — runs immediately, no tests required
- `workflow_run` from Test Workflow completing successfully — triggered by tag pushes

**Jobs:**

#### `detect-changes`
Uses `dorny/paths-filter` to determine which services changed. Outputs boolean flags for `api-node` and `client-react`. On tag pushes, both services are always built regardless of file changes.

#### `generate-image-tag`
Generates an image tag based on the Git ref:
- **Tag push** → uses `github.ref_name` directly (e.g. `1.2.3`)
- **Branch push** → uses `git describe --tags --long` (e.g. `1.2.2-4-gabcdef1`)

#### `build-and-push`
Runs as a matrix strategy across `api-node` and `client-react`. Each matrix leg:
- Builds a multi-platform image (`linux/amd64`, `linux/arm64`) using Docker Buildx
- Uses GitHub Actions cache (`type=gha`) for Docker layer caching
- Pushes to DockerHub under `alextsoh/<service>:<tag>`
- Skips entirely if `should_run` is false for that service

#### `update-manifests`
Runs after a successful build. Uses Kustomize to patch image tags in the GitOps manifests:
- Always updates `App/k8s/kustomize/dev/kustomization.yaml`
- On tag push (`is_prod=true`), also updates `App/k8s/kustomize/prod/kustomization.yaml`

Opens a pull request via `peter-evans/create-pull-request` targeting `main` with the updated manifests.

---
<img src="assets/ci-flow.png" width="350"/>

---
## Kubernetes & Kustomize Structure

The cluster configuration uses a **Kustomize overlay pattern**

- **dev** — runs on a local Kind cluster. Used for development and testing manifests locally before promoting to production.
- **prod** — runs on **AKS**. Updated automatically on **tagged releases** only. Includes additional resources for **secrets management**, **blue/green deployments** via **Argo Rollouts**, and **external secret synchronization**.

Both environments are managed by **ArgoCD** and use **Gateway API** with **Traefik** for traffic routing.
```text
.
├── base
│   ├── api-node
│   │   ├── Deployment.yaml
│   │   ├── Secret.yaml
│   │   ├── Service.yaml
│   │   └── kustomization.yaml
│   ├── client-react
│   │   ├── Deployment.yaml
│   │   ├── Service.yaml
│   │   └── kustomization.yaml
│   ├── cnpg
│   │   ├── kustomization.yaml
│   │   └── postgres-cluster.yaml
│   ├── kustomization.yaml
│   ├── migrator
│   │   ├── kustomization.yaml
│   │   └── migrator.yaml
│   └── namespaces.yaml
├── dev
│   ├── gateway.yaml
│   ├── httproute.yaml
│   ├── kustomization.yaml
│   ├── nginx.conf
│   ├── patches
│   │   ├── api-node-patch.yaml
│   │   ├── api-node-secret-patch.yaml
│   │   ├── client-react-patch.yaml
│   │   ├── cnpg-cluster-patch.yaml
│   │   └── migrator-patch.yaml
│   ├── postgres-namespace.yaml
│   └── secret-pg.yaml
└── prod
    ├── Rollout.client-react.yaml
    ├── Service-client-react-nginx-bluegreen.yaml
    ├── gateway.yaml
    ├── httproute.yaml
    ├── kustomization.yaml
    ├── nginx.conf
    ├── patches
    │   ├── api-node-patch.yaml
    │   ├── api-node-secret-patch.yaml
    │   ├── cnpg-cluster-patch.yaml
    │   └── migrator-patch.yaml
    ├── postgres-namespace.yaml
    ├── postgres-secret-sync.yaml
    ├── secret-provider-class-api.yaml
    ├── secret-provider-class-postgres.yaml
    ├── service-account-api.yaml
    └── service-account-postgres.yaml
```
---

## ArgoCD

ArgoCD is the GitOps controller that syncs this repository to the cluster. It continuously watches the `main` branch and applies any drift between the desired state in Git and the actual state in the cluster.

Two ArgoCD applications are defined:

- `application-aks.yaml` — syncs the `prod` overlay to **AKS**
- `application-local.yaml` — syncs the `dev` overlay to the local **Kind** cluster

Apply the ArgoCD applications manually once to bootstrap the cluster:

After that, all deployments are driven by Git — merging a PR with updated image tags is enough to trigger a sync and roll out a new version.
```bash
kubectl apply f App/k8s/argocd/application-aks.yaml
```
<img src="assets/argocd.png" width="350"/>

## ArgoCD Access & Identity

ArgoCD uses **OIDC** with **Azure Workload Identity** for authentication — the `argocd-server` pod authenticates via a **Federated Credential** against the AKS OIDC issuer, no client secrets required. **Entra ID groups** are mapped to ArgoCD roles via `argocd-rbac-cm` for authorization.

## Blue/Green Deployment

Production deploys `client-react` using **Argo Rollouts** with a **blue/green strategy**. Two identical environments run in parallel — **blue** (active, live traffic) and **green** (preview, no traffic).

The active and preview services each have a label selector pointing to a specific **rollouts-pod-template-hash** — Argo Rollouts swaps live traffic by patching that selector to point to the new pods.

**Key resources in `prod` overlay:**
- `Rollout.client-react.yaml` — defines the blue/green strategy
- `Service-client-react-nginx-bluegreen.yaml` — two services for independent traffic routing

<img src="assets/rollout.png" width="350"/>

---

## Production Secret Management

The production environment retrieves secrets from **Azure Key Vault** via the **Secrets Store CSI Driver**, authenticated using **Azure Workload Identity**. Each service has a dedicated `ServiceAccount` with the Workload Identity annotation and a `SecretProviderClass` defining which Key Vault secrets to fetch.

```
Azure Key Vault
       │
       │  Workload Identity auth
       ▼
ServiceAccount ──► SecretProviderClass ──► CSI Driver ──► Pod volume mount
                                               │
                                               ▼
                                       Kubernetes Secret
                                               │
                                               ▼
                                       DATABASE_URL env var
```

### API — file mount

The CSI driver writes the secret directly to `/mnt/secrets/database-password` inside the pod. The app reads it via `fs.readFileSync()` using the `DATABASE_URL_FILE` env var.
```bash
kubectl exec -n my-app prod-api-node-7cb8456fd9-xp7qt -- cat /mnt/secrets/DB-URL-PROD
postgres://postgres:safepassword@prod-cnpg-db-rw.postgres.svc.cluster.local:5432/postgres?sslmode=disable
```
### db-migrator — Kubernetes Secret sync

The CSI driver syncs the Key Vault value into a Kubernetes Secret (`my-app-secrets-sync`) via `secretObjects`. The pod reads it through `secretKeyRef` as `DATABASE_URL`.

The `SecretProviderClass` is referenced in the migrator patch using the kustomize-prefixed name (`prod-my-app-secrets`) to match the rendered resource name in the prod overlay.

A dummy **Job** (`postgres-secret-sync`) runs at **sync wave `-2`** to trigger the **Secrets Store CSI Driver** to fetch the PostgreSQL credentials from **Azure Key Vault** and sync them into a Kubernetes Secret before any cnpg pods start.

---

## Nginx Configuration Injection

The Nginx config is injected at runtime via a **Kubernetes ConfigMap** and a **volume mount**, allowing environment-specific configs without rebuilding the image.

1. The Kustomize overlay (`dev`/`prod`) uses `configMapGenerator` to create a ConfigMap from `nginx.conf`
2. The `Deployment`/`Rollout` defines a volume sourcing from that ConfigMap
3. The container mounts the config file into `/etc/nginx/conf.d/default.conf` at startup

```yaml
volumes:
  - name: nginx-config
    configMap:
      name: nginx-config
containers:
  - name: client-react
    volumeMounts:
      - name: nginx-config
        mountPath: /etc/nginx/conf.d/default.conf
        subPath: default.conf
```