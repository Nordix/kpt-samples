# Manual Runbook — Deploy otel-demo via Porch + Flux (no script)

This walks through everything `deployment/deploy.sh` automates, done by hand with
`porchctl`, `kubectl`, `flux`, and `kind`. It runs a **management cluster** (Porch +
Flux) that deploys the OpenTelemetry demo shop onto a **separate per-region
workload cluster**, using a two-tier GitOps model with Flux remote-apply.

## Model overview

- **Management cluster** (`porch-test`): runs Porch and Flux. No workloads here.
- **Region cluster** (one kind cluster per region, e.g. `ireland`): runs the shop.
- Flux on the management cluster applies each region's app to its region cluster
  **remotely**, via a kubeconfig Secret (`Kustomization.spec.kubeConfig`).

Per region there is **one Gitea repo** with **two directories**, each a Porch package:

```
<region>.git
├── /apps          -> Porch repo "<region>-apps"         (the shop, from kpt-pkg)
└── /flux-config   -> Porch repo "<region>-flux-config"  (Flux wiring, from flux-blueprint)

MANAGEMENT cluster (all Flux + Porch objects live here, in ns <region>-otel-demo):
  GitRepository/<region>-flux + Kustomization/<region>-flux   (watches /flux-config)
        └─► applies the wiring, which is:
              GitRepository/<region> + Kustomization/<region>-otel-demo
                 (watches /apps, spec.kubeConfig -> <region> cluster)
                    └─► applies the shop onto the REGION cluster, ns <region>-otel-demo
```

The region cluster's API must be reachable from the management cluster's pods. On
kind, both clusters share the `kind` docker network, so we point the kubeconfig at
the region control-plane's container IP (which is a cert SAN, so TLS verifies).

Two blueprints live in the `blueprints` repo:
- `otel-demo-blueprint`  (from `kpt-pkg/`)  — the shop app
- `flux-blueprint`            (from `flux-blueprint/`) — the Flux wiring template (carries kubeConfig)

Prereqs: a management cluster with Porch installed, plus `kubectl`, `porchctl`,
`flux`, `kpt`, `kind` on PATH. The branded images are pulled from a container
registry (see below), so `docker` and a local build are **optional** — only needed
if you want to build the images yourself for offline/air-gapped use.

The branded store images are pre-published under
`ghcr.io/kptdev/kpt-samples/otel-demo/<name>:v1` and referenced directly by
the app package, so region clusters pull them over the network — no `kind load`
needed. (Astronomy's `image-provider`/`load-generator` use the upstream
`ghcr.io/open-telemetry/demo:2.2.0-*` images.)

---

## Environment variables — set these once

Every command below references these. Copy-paste and adjust to your environment,
then `export` them in the shell you'll run the rest of the runbook in.

```bash
# --- where you cloned/copied this project ---
# REPO must be the repository ROOT — the directory that contains kpt-pkg/,
# flux-blueprint/, astronomy/, florist/, deployment/. If you're in deployment/,
# set it to the parent, e.g.  export REPO=$(cd .. && pwd)  or  export REPO=~/otel-demo
export REPO=$(pwd)                       # run this from the repo root, or override below

# --- clusters / namespaces ---
export PORCH_NS=porch-demo               # namespace Porch resources live in (mgmt cluster)
export FLUX_NS=flux-system               # namespace Flux controllers live in (mgmt cluster)
export MGMT_CLUSTER=porch-test           # kind name of the management cluster
export MGMT_CONTEXT=kind-${MGMT_CLUSTER} # kubectl context for the management cluster

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
export APP_BLUEPRINT=otel-demo-blueprint
export FLUX_BLUEPRINT=flux-blueprint
export APP_PKG=otel-demo            # app package name in <region>-apps
export FLUX_PKG=flux                     # flux package name in <region>-flux-config

# --- the region you are deploying ---
export REGION=ireland                    # us|india|czech-republic|china|ireland|sweden|hungary
export STORE=astronomy                   # astronomy | florist
export NS=${REGION}-otel-demo            # deployment namespace (same name on mgmt + region cluster)
export REGION_CLUSTER=${REGION}          # kind name of the region workload cluster
export REGION_CONTEXT=kind-${REGION_CLUSTER}
export KUBECONFIG_SECRET=${REGION}-kubeconfig   # Secret (on mgmt) holding the region cluster kubeconfig
```

> **Verify `GITEA_HOST` before proceeding.** If Porch's repository sync fails with
> `no route to host` / `repository not found`, the IP is wrong — re-check
> `kubectl get svc -n gitea` and update `GITEA_HOST`.

---

## 0. One-time: namespace + git auth secret

These live on the **management** cluster, so target it explicitly with
`--context "$MGMT_CONTEXT"` (don't rely on the current context).

```bash
kubectl --context "$MGMT_CONTEXT" create namespace "$PORCH_NS" 2>/dev/null || true

# Porch (and later Flux) authenticate to Gitea with this basic-auth Secret.
kubectl --context "$MGMT_CONTEXT" create secret generic "$GIT_SECRET" -n "$PORCH_NS" \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$GITEA_USER" \
  --from-literal=password="$GITEA_PASS"
```

---

## 1. Create the region workload cluster (+ kubeconfig Secret)

The branding layer points frontend/ad/llm at the pre-published
`ghcr.io/kptdev/kpt-samples/otel-demo/<store>-*:v1` images, which the region
cluster pulls automatically — so there is **no build/load step** in the normal
flow. You only need to create the region cluster and register its kubeconfig on
the management cluster. (To build the images yourself for offline/air-gapped use,
see **[IMAGEBUILD.md](./IMAGEBUILD.md)**.)

> **Important:** `kind create cluster` switches your *current* kubectl context to
> the new region cluster. Every step after this one operates on the **management**
> cluster (Porch, blueprints, Flux roots), so switch the context back immediately
> after creating the region cluster (the command block below does this). If you
> skip it, commands like `kubectl apply` for a Porch `Repository` will hit the
> region cluster and fail with `no matches for kind "Repository"`.

```bash
# create the region kind cluster (if missing)
kind get clusters | grep -qx "$REGION_CLUSTER" || kind create cluster --name "$REGION_CLUSTER"

# IMPORTANT: `kind create` just switched the current context to the region cluster.
# Switch back to the management cluster for all the Porch/Flux steps that follow.
kubectl config use-context "$MGMT_CONTEXT"

# control-plane container IP on the shared 'kind' docker network
REGION_IP=$(docker inspect "${REGION_CLUSTER}-control-plane" \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)
echo "region cluster IP: $REGION_IP"

# internal kubeconfig, rewritten to the container IP (which is a cert SAN)
kind get kubeconfig --internal --name "$REGION_CLUSTER" \
  | sed "s#server: https://${REGION_CLUSTER}-control-plane:6443#server: https://${REGION_IP}:6443#" \
  > /tmp/${REGION}.kubeconfig

# store it as a Secret on the MANAGEMENT cluster (Flux reads it for remote-apply)
kubectl --context "$MGMT_CONTEXT" create namespace "$NS" 2>/dev/null || true
kubectl --context "$MGMT_CONTEXT" create secret generic "$KUBECONFIG_SECRET" -n "$NS" \
  --from-file=value=/tmp/${REGION}.kubeconfig \
  --dry-run=client -o yaml | kubectl --context "$MGMT_CONTEXT" apply -f -
```

---

## 2. Register the `blueprints` Porch repository

The blueprints live in a Gitea repo `blueprints.git`, registered in Porch as a
non-deployment (blueprint) repository. Create the Gitea repo if missing, then register.

```bash
# create the Gitea repo if missing (idempotent)
curl -s -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_API/user/repos" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$BLUEPRINT_REPO\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" >/dev/null

# register it in Porch (deployment: false)
kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
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

kubectl --context "$MGMT_CONTEXT" get repository "$BLUEPRINT_REPO" -n "$PORCH_NS"   # wait for READY=True
```

---

## 3. Publish the two blueprints

Pattern for a new package: init → pull (for `.KptRevisionMetadata`) → overlay
content → push (server-side render) → propose → approve.

### 3a. App blueprint (has subpackages shop/ + observability/)

`$REPO` must be the repo root (the directory that contains `kpt-pkg/`).
The `&&` chaining is deliberate: if the copy fails (e.g. wrong `$REPO`), it stops
**before** pushing/approving, so you never publish an empty blueprint.

```bash
# sanity: $REPO must contain the source blueprint dir
test -d "$REPO/kpt-pkg" || { echo "ERROR: \$REPO ($REPO) has no kpt-pkg/ — set REPO to the repo root"; }

porchctl rpkg init "$APP_BLUEPRINT" --repository="$BLUEPRINT_REPO" \
  --workspace=v1 -n "$PORCH_NS"

DRAFT=${BLUEPRINT_REPO}.${APP_BLUEPRINT}.v1
rm -rf /tmp/bp \
  && porchctl rpkg pull "$DRAFT" /tmp/bp -n "$PORCH_NS" \
  && cp -r "$REPO/kpt-pkg/." /tmp/bp/ \
  && porchctl rpkg push    "$DRAFT" /tmp/bp -n "$PORCH_NS" \
  && porchctl rpkg propose "$DRAFT" -n "$PORCH_NS" \
  && porchctl rpkg approve "$DRAFT" -n "$PORCH_NS"
```

### 3b. Flux blueprint

```bash
test -d "$REPO/flux-blueprint" || { echo "ERROR: \$REPO ($REPO) has no flux-blueprint/ — set REPO to the repo root"; }

porchctl rpkg init "$FLUX_BLUEPRINT" --repository="$BLUEPRINT_REPO" --workspace=v1 -n "$PORCH_NS"

FDRAFT=${BLUEPRINT_REPO}.${FLUX_BLUEPRINT}.v1
rm -rf /tmp/fb \
  && porchctl rpkg pull "$FDRAFT" /tmp/fb -n "$PORCH_NS" \
  && cp -r "$REPO/flux-blueprint/." /tmp/fb/ \
  && porchctl rpkg push    "$FDRAFT" /tmp/fb -n "$PORCH_NS" \
  && porchctl rpkg propose "$FDRAFT" -n "$PORCH_NS" \
  && porchctl rpkg approve "$FDRAFT" -n "$PORCH_NS"
```

> Tip: to publish a *new revision* later, use
> `porchctl rpkg copy <latest-pkgrev> --workspace=v2 -n "$PORCH_NS"` instead of
> `init`, then pull/overlay/push/propose/approve.
>
> **Never push a draft you haven't populated.** If the `cp` step fails (wrong
> `$REPO`, missing source dir), do **not** run `push`/`approve` — you would
> publish an empty package over the blueprint. The `&&` chaining above prevents
> this automatically.

---

## 4. Install Flux

```bash
flux install
```

Flux's source-controller reads the git secret from the GitRepository's namespace.
Because we place Flux objects in the region namespace, the secret is replicated
there in step 8 — nothing else is needed in `$FLUX_NS` for this model.

---

## 5. Register the region's two Porch repos

The Gitea repo `${REGION}.git` must exist first (create via the API if needed):

```bash
curl -s -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_API/user/repos" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$REGION\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" >/dev/null
```

Register both directories as Porch repositories:

```bash
# <region>-apps -> /apps
kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
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
kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
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

kubectl --context "$MGMT_CONTEXT" get repository -n "$PORCH_NS" | grep "$REGION"   # wait for READY=True
```

---

## 6. Deploy the app package (clone blueprint into <region>-apps)

Clone the app blueprint into the region's apps repo, set the three config values
(namespace, region, store), and publish. Porch re-renders on push.

```bash
APR=${REGION}-apps.${APP_PKG}.v1

porchctl rpkg clone "${BLUEPRINT_REPO}.${APP_BLUEPRINT}.v1" "$APP_PKG" \
  --repository="${REGION}-apps" --workspace=v1 -n "$PORCH_NS"

rm -rf /tmp/app && porchctl rpkg pull "$APR" /tmp/app -n "$PORCH_NS"

# Guard: the pulled package must have the expected structure before we customize
# and push. If the blueprint was empty/wrong, stop here rather than publishing junk.
test -d /tmp/app/regional && test -f /tmp/app/app-config.yaml \
  || { echo "ERROR: /tmp/app is missing regional/ or app-config.yaml — check the blueprint content, do NOT push"; }

# All user-facing config lives in a single ConfigMap: /tmp/app/app-config.yaml
# (keys: namespace, storeType, region, profile, chaos). Edit the three
# per-deployment keys in place; profile/chaos keep the blueprint defaults.
# Only push/publish if the customization succeeds (&&-chained so a failed sed aborts).
sed -i \
  -e "s|^\([[:space:]]*\)namespace:.*|\1namespace: ${NS}|" \
  -e "s|^\([[:space:]]*\)region:.*|\1region: ${REGION}|" \
  -e "s|^\([[:space:]]*\)storeType:.*|\1storeType: ${STORE}|" \
  /tmp/app/app-config.yaml \
  && porchctl rpkg push    "$APR" /tmp/app -n "$PORCH_NS" \
  && porchctl rpkg propose "$APR" -n "$PORCH_NS" \
  && porchctl rpkg approve "$APR" -n "$PORCH_NS"
```

Valid regions: `us, india, czech-republic, china, ireland, sweden, hungary`.
Valid stores: `astronomy, florist`.

---

## 7. Publish the Flux wiring package (clone flux-blueprint into <region>-flux-config)

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
  namespace: ${NS}         # where the Flux objects live (mgmt) + app namespace (region)
  appPath: apps            # dir in ${REGION}.git where the shop package lives
  kubeconfigSecret: ${KUBECONFIG_SECRET}   # makes Flux apply the app to the REGION cluster
  gitBase: ${GIT_BASE}     # Git server base; GitRepository url = <gitBase>/<repo>.git
EOF

# Verify the config was written with real values before publishing. In particular
# kubeconfigSecret must NOT be empty/PLACEHOLDER — otherwise the setup-flux mutator
# drops kubeConfig and Flux applies the app to the MANAGEMENT cluster instead of
# the region cluster.
grep -q "kubeconfigSecret: ${KUBECONFIG_SECRET}" /tmp/flux/flux-config.yaml \
  && [ -n "${KUBECONFIG_SECRET}" ] \
  && porchctl rpkg push    "$FPR" /tmp/flux -n "$PORCH_NS" \
  && porchctl rpkg propose "$FPR" -n "$PORCH_NS" \
  && porchctl rpkg approve "$FPR" -n "$PORCH_NS"
```

The render stamps the region's `GitRepository`/`Kustomization` (both in `$NS`,
pointing at `${REGION}.git` `/apps`) and — because `kubeconfigSecret` is set —
adds `spec.kubeConfig` so Flux applies the app to the **region** cluster, not the
management cluster.

---

## 8. Seed the per-region Flux root (on the management cluster)

Replicate the git secret into the region namespace **on the management cluster**,
and create ONE root `GitRepository` + `Kustomization` that watches `/flux-config`.
The root applies the flux-config package, which creates the inner Kustomization
that (via `kubeConfig`) applies the app to the **region** cluster.

```bash
kubectl --context "$MGMT_CONTEXT" create namespace "$NS" 2>/dev/null || true

# replicate git secret into the region namespace on the MGMT cluster (source-controller needs it)
kubectl --context "$MGMT_CONTEXT" get secret "$GIT_SECRET" -n "$PORCH_NS" -o yaml \
  | sed "s/namespace: ${PORCH_NS}/namespace: ${NS}/" \
  | grep -vE '^\s+(resourceVersion|uid|creationTimestamp|selfLink):' \
  | kubectl --context "$MGMT_CONTEXT" apply -n "$NS" -f -

# the root: watches ${REGION}.git /flux-config  (created on the MGMT cluster)
kubectl --context "$MGMT_CONTEXT" apply -f - <<EOF
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

## 9. Verify

Flux objects are on the **management** cluster; workloads run on the **region** cluster.

```bash
# management cluster: both Kustomizations should be Ready
kubectl --context "$MGMT_CONTEXT" get kustomization -n "$NS"
#   ${REGION}-flux      -> applies /flux-config (local)
#   ${NS}               -> applies /apps to the region cluster (kubeConfig)

# region cluster: the actual workloads
kubectl --context "$REGION_CONTEXT" get pods -n "$NS"
kubectl --context "$REGION_CONTEXT" get deploy frontend -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}'   # ghcr.io/kptdev/.../<store>-frontend:v1
```

View the store (port-forward blocks; own terminal) — against the REGION cluster:
```bash
kubectl --context "$REGION_CONTEXT" port-forward -n "$NS" svc/frontend-proxy 8080:8080
# Storefront:  http://localhost:8080/
# Grafana:     http://localhost:8080/grafana/     (503 until Grafana is Ready)
# Jaeger:      http://localhost:8080/jaeger/ui/
# Feature UI:  http://localhost:8080/feature/     (flagd-ui)
# Load gen:    http://localhost:8080/loadgen/
# (trailing slashes matter — these are Envoy path prefixes baked into frontend-proxy)
```

> Note: PostgreSQL seeds its catalog from init.sql only on first boot. After a
> branding change, restart it on the REGION cluster to re-seed:
> `kubectl --context "$REGION_CONTEXT" rollout restart deploy/postgresql deploy/product-catalog -n "$NS"`

---

## Updating a region (pull newer blueprints, keep customizations)

Publish a new blueprint revision (step 3 with `rpkg copy`), then upgrade the
downstream via structural 3-way merge (preserves namespace/region/branding/kubeConfig).
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

flux --context "$MGMT_CONTEXT" reconcile kustomization "${REGION}-flux" -n "$NS" --with-source
```

---

## Teardown a region

```bash
# 1. delete the Flux root on the MGMT cluster (prune removes the wiring + remote workloads)
kubectl --context "$MGMT_CONTEXT" delete kustomization "${REGION}-flux" -n "$NS" --ignore-not-found
kubectl --context "$MGMT_CONTEXT" delete gitrepository "${REGION}-flux" -n "$NS" --ignore-not-found

# 2. delete the Porch packages (drafts first, then the main aggregate)
for pr in $(porchctl rpkg get -n "$PORCH_NS" | awk -v re="^${REGION}-(apps|flux-config)$" '$7 ~ re {print $1}'); do
  porchctl rpkg propose-delete "$pr" -n "$PORCH_NS"
  porchctl rpkg del "$pr" -n "$PORCH_NS"
done

# 3. delete the region namespace + kubeconfig secret on the MGMT cluster
kubectl --context "$MGMT_CONTEXT" delete ns "$NS" --ignore-not-found

# 4. delete the region workload cluster entirely (removes all workloads)
kind delete cluster --name "$REGION_CLUSTER"
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

Re-`export REGION=<name>` (and `STORE`, `NS`) at the top, then repeat steps 5–9.
The blueprints (step 3), the `blueprints` repo (step 2), and Flux install
(step 4) are shared — do them once.
