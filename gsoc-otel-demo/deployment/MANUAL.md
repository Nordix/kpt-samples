# Manual Runbook — Deploy gsoc-otel-demo via Porch + Flux (no script)

This walks through everything `deployment/deploy.sh` automates, done by hand with
`porchctl`, `kubectl`, and `flux`. It deploys the OpenTelemetry demo shop into a
per-region namespace using a two-tier GitOps model.

## Model overview

Per region there is **one Gitea repo** with **two directories**, each a Porch package:

```
<region>.git
├── /apps          -> Porch repo "<region>-apps"         (the shop, from app-blueprint)
└── /flux-config   -> Porch repo "<region>-flux-config"  (Flux wiring, from flux-blueprint)

Flux (all objects in <region>-otel-demo namespace):
  GitRepository/<region>-flux + Kustomization/<region>-flux   (watches /flux-config)
        └─► applies the wiring, which is:
              GitRepository/<region> + Kustomization/<region>-otel-demo  (watches /apps)
                    └─► applies the shop into <region>-otel-demo
```

Two blueprints live in the `blueprints` repo:
- `gsoc-otel-demo-blueprint`  (from `app-blueprint/`)  — the shop app
- `flux-blueprint`            (from `flux-blueprint/`) — the Flux wiring template

Prereqs: a cluster with Porch installed, plus `kubectl`, `porchctl`, `flux`,
`kpt`, `docker`, `kind` on PATH.

---

## Environment variables — set these once

Every command below references these. Copy-paste and adjust to your environment,
then `export` them in the shell you'll run the rest of the runbook in.

```bash
# --- where you cloned/copied this project ---
export REPO=$(pwd)                       # or e.g. export REPO=~/gsoc-otel-demo

# --- cluster / namespaces ---
export PORCH_NS=porch-demo               # namespace Porch resources live in
export FLUX_NS=flux-system               # namespace Flux controllers live in
export KIND_CLUSTER=porch-test           # kind cluster name (for `kind load`)

# --- Gitea backend ---
# IMPORTANT: verify this IP/port. It is the Gitea service address reachable
# FROM INSIDE the cluster (e.g. the LoadBalancer/ClusterIP). Find it with:
#   kubectl get svc -n gitea
# and use the address Porch/Flux can reach (often a MetalLB LB IP).
export GITEA_HOST=172.18.255.204:3000
export GITEA_ORG=porch                   # Gitea user/org that owns the repos
export GITEA_USER=porch                  # API + git basic-auth username
export GITEA_PASS=secret                 # API + git basic-auth password/token
export GIT_BASE=http://${GITEA_HOST}/${GITEA_ORG}
export GITEA_API=http://${GITEA_HOST}/api/v1
export GIT_SECRET=gitea                  # k8s Secret name (basic-auth)

# --- fixed package names (usually leave as-is) ---
export BLUEPRINT_REPO=blueprints
export APP_BLUEPRINT=gsoc-otel-demo-blueprint
export FLUX_BLUEPRINT=flux-blueprint
export APP_PKG=gsoc-otel-demo            # app package name in <region>-apps
export FLUX_PKG=flux                     # flux package name in <region>-flux-config

# --- the region you are deploying ---
export REGION=ireland                    # us|india|czech-republic|china|ireland|sweden|hungary
export STORE=astronomy                   # astronomy | florist
export NS=${REGION}-otel-demo            # deployment namespace
```

> **Verify `GITEA_HOST` before proceeding.** If Porch's repository sync fails with
> `no route to host` / `repository not found`, the IP is wrong — re-check
> `kubectl get svc -n gitea` and update `GITEA_HOST`.

---

## 0. One-time: namespace + git auth secret

```bash
kubectl create namespace "$PORCH_NS" 2>/dev/null || true

# Porch (and later Flux) authenticate to Gitea with this basic-auth Secret.
kubectl create secret generic "$GIT_SECRET" -n "$PORCH_NS" \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$GITEA_USER" \
  --from-literal=password="$GITEA_PASS"
```

---

## 1. Build + load the branded images (astronomy or florist)

The branding layer points frontend/ad/llm/image-provider/load-generator at
locally-built `<store>-*:v1` images. Build them from source and load into kind.

Astronomy:
```bash
cd "$REPO/astronomy"
docker build -t astronomy-frontend:v1 ./frontend
docker build --build-arg OTEL_JAVA_AGENT_VERSION=2.11.0 -t astronomy-ad:v1 ./ad
docker build -t astronomy-llm:v1 ./llm
docker build -t astronomy-email:v1 ./email
for i in astronomy-frontend astronomy-ad astronomy-llm astronomy-email; do
  kind load docker-image $i:v1 --name "$KIND_CLUSTER"
done
```

Florist (only if deploying a florist store):
```bash
cd "$REPO/florist"
docker build -t florist-image-provider:v1 ./image-provider
docker build -t florist-load-generator:v1 ./load-generator
docker build -t email:v1 ./email
docker build --build-arg OTEL_JAVA_AGENT_VERSION=2.11.0 -t florist-ad:v1 ./ad
docker build -t florist-llm:v1 ./llm
docker build -t florist-frontend:v1 ./frontend
for i in florist-image-provider florist-load-generator email florist-ad florist-llm florist-frontend; do
  kind load docker-image $i:v1 --name "$KIND_CLUSTER"
done
```

---

## 1b. Register the `blueprints` Porch repository

The blueprints live in a Gitea repo `blueprints.git`, registered in Porch as a
non-deployment (blueprint) repository. Create the Gitea repo if missing, then register.

```bash
# create the Gitea repo if missing (idempotent)
curl -s -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_API/user/repos" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$BLUEPRINT_REPO\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" >/dev/null

# register it in Porch (deployment: false)
kubectl apply -f - <<EOF
apiVersion: config.porch.kpt.dev/v1alpha1
kind: Repository
metadata:
  name: ${BLUEPRINT_REPO}
  namespace: ${PORCH_NS}
spec:
  description: ${BLUEPRINT_REPO}
  content: Package
  deployment: false
  type: git
  git:
    repo: ${GIT_BASE}/${BLUEPRINT_REPO}.git
    directory: /
    branch: main
    createBranch: true
    secretRef:
      name: ${GIT_SECRET}
  sync:
    schedule: "0 2 * * *"
EOF

kubectl get repository "$BLUEPRINT_REPO" -n "$PORCH_NS"   # wait for READY=True
```

---

## 2. Publish the two blueprints

Pattern for a new package: init → pull (for `.KptRevisionMetadata`) → overlay
content → push (server-side render) → propose → approve.

### 2a. App blueprint (has subpackages shop/ + observability/)

```bash
cd "$REPO"
porchctl rpkg init "$APP_BLUEPRINT" --repository="$BLUEPRINT_REPO" \
  --workspace=v1 -n "$PORCH_NS"

DRAFT=${BLUEPRINT_REPO}.${APP_BLUEPRINT}.v1
rm -rf /tmp/bp && porchctl rpkg pull "$DRAFT" /tmp/bp -n "$PORCH_NS"
cp -r app-blueprint/. /tmp/bp/

porchctl rpkg push    "$DRAFT" /tmp/bp -n "$PORCH_NS"
porchctl rpkg propose "$DRAFT" -n "$PORCH_NS"
porchctl rpkg approve "$DRAFT" -n "$PORCH_NS"
```

### 2b. Flux blueprint

```bash
cd "$REPO"
porchctl rpkg init "$FLUX_BLUEPRINT" --repository="$BLUEPRINT_REPO" --workspace=v1 -n "$PORCH_NS"

FDRAFT=${BLUEPRINT_REPO}.${FLUX_BLUEPRINT}.v1
rm -rf /tmp/fb && porchctl rpkg pull "$FDRAFT" /tmp/fb -n "$PORCH_NS"
cp -r flux-blueprint/. /tmp/fb/

porchctl rpkg push    "$FDRAFT" /tmp/fb -n "$PORCH_NS"
porchctl rpkg propose "$FDRAFT" -n "$PORCH_NS"
porchctl rpkg approve "$FDRAFT" -n "$PORCH_NS"
```

> Tip: to publish a *new revision* later, use
> `porchctl rpkg copy <latest-pkgrev> --workspace=v2 -n "$PORCH_NS"` instead of
> `init`, then pull/overlay/push/propose/approve.

---

## 3. Install Flux

```bash
flux install
```

Flux's source-controller reads the git secret from the GitRepository's namespace.
Because we place Flux objects in the region namespace, the secret is replicated
there in step 7 — nothing else is needed in `$FLUX_NS` for this model.

---

## 4. Register the region's two Porch repos

The Gitea repo `${REGION}.git` must exist first (create via the API if needed):

```bash
curl -s -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_API/user/repos" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$REGION\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" >/dev/null
```

Register both directories as Porch repositories:

```bash
# <region>-apps -> /apps
kubectl apply -f - <<EOF
apiVersion: config.porch.kpt.dev/v1alpha1
kind: Repository
metadata:
  name: ${REGION}-apps
  namespace: ${PORCH_NS}
spec:
  description: ${REGION}-apps
  content: Package
  deployment: true
  type: git
  git:
    repo: ${GIT_BASE}/${REGION}.git
    directory: /apps
    branch: main
    createBranch: true
    secretRef:
      name: ${GIT_SECRET}
  sync:
    schedule: "0 2 * * *"
EOF

# <region>-flux-config -> /flux-config
kubectl apply -f - <<EOF
apiVersion: config.porch.kpt.dev/v1alpha1
kind: Repository
metadata:
  name: ${REGION}-flux-config
  namespace: ${PORCH_NS}
spec:
  description: ${REGION}-flux-config
  content: Package
  deployment: true
  type: git
  git:
    repo: ${GIT_BASE}/${REGION}.git
    directory: /flux-config
    branch: main
    createBranch: true
    secretRef:
      name: ${GIT_SECRET}
  sync:
    schedule: "0 2 * * *"
EOF

kubectl get repository -n "$PORCH_NS" | grep "$REGION"   # wait for READY=True
```

---

## 5. Deploy the app package (clone blueprint into <region>-apps)

Clone the app blueprint into the region's apps repo, set the three config values
(namespace, region, store), and publish. Porch re-renders on push.

```bash
APR=${REGION}-apps.${APP_PKG}.v1

porchctl rpkg clone "${BLUEPRINT_REPO}.${APP_BLUEPRINT}.v1" "$APP_PKG" \
  --repository="${REGION}-apps" --workspace=v1 -n "$PORCH_NS"

rm -rf /tmp/app && porchctl rpkg pull "$APR" /tmp/app -n "$PORCH_NS"

cat > /tmp/app/namespace-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: namespace-config
  annotations: { config.kubernetes.io/local-config: "true" }
data:
  namespace: ${NS}
EOF

cat > /tmp/app/regional/region-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: region-config
  annotations: { config.kubernetes.io/local-config: "true" }
data:
  region: ${REGION}
EOF

sed -i "s/storeType: .*/storeType: ${STORE}/" /tmp/app/branding/branding-config.yaml

porchctl rpkg push    "$APR" /tmp/app -n "$PORCH_NS"
porchctl rpkg propose "$APR" -n "$PORCH_NS"
porchctl rpkg approve "$APR" -n "$PORCH_NS"
```

Valid regions: `us, india, czech-republic, china, ireland, sweden, hungary`.

---

## 6. Publish the Flux wiring package (clone flux-blueprint into <region>-flux-config)

```bash
FPR=${REGION}-flux-config.${FLUX_PKG}.v1

porchctl rpkg clone "${BLUEPRINT_REPO}.${FLUX_BLUEPRINT}.v1" "$FLUX_PKG" \
  --repository="${REGION}-flux-config" --workspace=v1 -n "$PORCH_NS"

rm -rf /tmp/flux && porchctl rpkg pull "$FPR" /tmp/flux -n "$PORCH_NS"

cat > /tmp/flux/flux-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: flux-config
  annotations: { config.kubernetes.io/local-config: "true" }
data:
  repo: ${REGION}          # Flux GitRepository name + Gitea repo
  namespace: ${NS}         # where the Flux objects + app land
  appPath: apps            # dir in ${REGION}.git where the shop package lives
EOF

porchctl rpkg push    "$FPR" /tmp/flux -n "$PORCH_NS"
porchctl rpkg propose "$FPR" -n "$PORCH_NS"
porchctl rpkg approve "$FPR" -n "$PORCH_NS"
```

The render stamps the region's `GitRepository`/`Kustomization` (both in `$NS`,
pointing at `${REGION}.git` `/apps`).

---

## 7. Seed the per-region Flux root

Create the namespace, replicate the git secret into it, and create ONE root
`GitRepository` + `Kustomization` that watches `/flux-config`. Flux applies the rest.

```bash
kubectl create namespace "$NS" 2>/dev/null || true

# replicate git secret into the region namespace (source-controller needs it there)
kubectl get secret "$GIT_SECRET" -n "$PORCH_NS" -o yaml \
  | sed "s/namespace: ${PORCH_NS}/namespace: ${NS}/" \
  | grep -vE '^\s+(resourceVersion|uid|creationTimestamp|selfLink):' \
  | kubectl apply -n "$NS" -f -

# the root: watches ${REGION}.git /flux-config
kubectl apply -f - <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: ${REGION}-flux
  namespace: ${NS}
spec:
  interval: 1m
  url: ${GIT_BASE}/${REGION}.git
  ref:
    branch: main
  secretRef:
    name: ${GIT_SECRET}
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${REGION}-flux
  namespace: ${NS}
spec:
  interval: 2m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: ${REGION}-flux
  path: ./flux-config
  prune: true
  wait: false
EOF
```

---

## 8. Verify

```bash
flux get sources git -n "$NS"
flux get kustomizations -n "$NS"
#   ${REGION}-flux -> applies /flux-config
#   ${NS}          -> applies /apps

kubectl get pods -n "$NS"
kubectl get deploy frontend -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}'   # astronomy- or florist-frontend:v1
```

View the store (port-forward blocks; own terminal):
```bash
kubectl port-forward -n "$NS" svc/frontend-proxy 8080:8080
# Storefront:  http://localhost:8080/
# Grafana:     http://localhost:8080/grafana/     (503 until Grafana is Ready)
# Jaeger:      http://localhost:8080/jaeger/ui/
# Feature UI:  http://localhost:8080/feature/     (flagd-ui)
# Load gen:    http://localhost:8080/loadgen/
# (trailing slashes matter — these are Envoy path prefixes baked into frontend-proxy)
```

> Note: PostgreSQL seeds its catalog from init.sql only on first boot. After a
> branding change, restart it to re-seed:
> `kubectl rollout restart deploy/postgresql deploy/product-catalog -n "$NS"`

---

## Updating a region (pull newer blueprints, keep customizations)

Publish a new blueprint revision (step 2 with `rpkg copy`), then upgrade the
downstream via structural 3-way merge (preserves namespace/region/branding).
Set `NEW_APP_REV` / `NEW_FLUX_REV` to the new blueprint REVISION numbers.

```bash
porchctl rpkg upgrade "${REGION}-apps.${APP_PKG}.v1" \
  --revision="$NEW_APP_REV" --workspace=v2 -n "$PORCH_NS"
porchctl rpkg propose "${REGION}-apps.${APP_PKG}.v2" -n "$PORCH_NS"
porchctl rpkg approve "${REGION}-apps.${APP_PKG}.v2" -n "$PORCH_NS"

porchctl rpkg upgrade "${REGION}-flux-config.${FLUX_PKG}.v1" \
  --revision="$NEW_FLUX_REV" --workspace=v2 -n "$PORCH_NS"
porchctl rpkg propose "${REGION}-flux-config.${FLUX_PKG}.v2" -n "$PORCH_NS"
porchctl rpkg approve "${REGION}-flux-config.${FLUX_PKG}.v2" -n "$PORCH_NS"

flux reconcile kustomization "${REGION}-flux" -n "$NS" --with-source
```

---

## Teardown a region

```bash
# 1. delete the Flux root (prune:true removes the wiring, which removes the app)
kubectl delete kustomization "${REGION}-flux" -n "$NS" --ignore-not-found
kubectl delete gitrepository "${REGION}-flux" -n "$NS" --ignore-not-found

# 2. delete the Porch packages (drafts first, then the main aggregate)
for pr in $(porchctl rpkg get -n "$PORCH_NS" | awk -v re="^${REGION}-(apps|flux-config)$" '$7 ~ re {print $1}'); do
  porchctl rpkg propose-delete "$pr" -n "$PORCH_NS"
  porchctl rpkg del "$pr" -n "$PORCH_NS"
done

# 3. delete the namespace + namespace-prefixed cluster RBAC
kubectl delete ns "$NS" --ignore-not-found
kubectl get clusterrole,clusterrolebinding -o name | grep "/${NS}-" | xargs -r kubectl delete
```

To also remove the blueprints and Flux:
```bash
for pr in $(porchctl rpkg get -n "$PORCH_NS" | awk '$2 ~ /-blueprint$/{print $1}'); do
  porchctl rpkg propose-delete "$pr" -n "$PORCH_NS"; porchctl rpkg del "$pr" -n "$PORCH_NS"
done
flux uninstall --silent
```

---

## Other regions

Re-`export REGION=<name>` (and `STORE`, `NS`) at the top, then repeat steps 4–8.
The blueprints (step 2), the `blueprints` repo (step 1b), and Flux install
(step 3) are shared — do them once.
