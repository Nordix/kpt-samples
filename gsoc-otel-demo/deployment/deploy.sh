#!/usr/bin/env bash
#
# deploy.sh — Automate the gsoc-otel-demo Porch + Flux deployment.
#
# Pipeline it automates (the manual flow, scripted):
#   1. build      Build + kind-load the locally-built branded images (astronomy/florist)
#   2. blueprint  Push the local app-blueprint/ package to the blueprints repo and publish it
#   3. deploy     Clone the blueprint into a deployments repo, set namespace + branding,
#                 publish, then create the Flux GitRepository + Kustomization
#   4. flux-init  Install Flux + replicate the git auth secret into flux-system
#   5. all        flux-init (if needed) + blueprint + one or more deploy targets
#
# Each deploy target is "<repo>:<namespace>:<storeType>", e.g.
#   deployments1:deployments1-otel-demo:astronomy
#   deployments2:deployments2-otel-demo:florist
#
# Requires: kubectl, kpt, porchctl, flux, docker, kind (for build), python3.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLUEPRINT_DIR="${BLUEPRINT_DIR:-$REPO_ROOT/app-blueprint}"
FLUX_BLUEPRINT_DIR="${FLUX_BLUEPRINT_DIR:-$REPO_ROOT/flux-blueprint}"
PACKAGE_NAME="${PACKAGE_NAME:-gsoc-otel-demo}"          # app package name inside <region>-apps repo
FLUX_PKG_NAME="${FLUX_PKG_NAME:-flux}"                  # flux package name inside <region>-flux-config repo
BLUEPRINT_NAME="${BLUEPRINT_NAME:-gsoc-otel-demo-blueprint}"
FLUX_BLUEPRINT_NAME="${FLUX_BLUEPRINT_NAME:-flux-blueprint}"  # published flux blueprint pkg name
BLUEPRINT_REPO="${BLUEPRINT_REPO:-blueprints}"
# Per region there are two Porch repos backed by one Gitea repo (different dirs):
#   <region>-apps         -> /apps         (the shop app package)
#   <region>-flux-config  -> /flux-config  (the Flux wiring package)
APPS_SUFFIX="${APPS_SUFFIX:--apps}"
FLUX_SUFFIX="${FLUX_SUFFIX:--flux-config}"
PORCH_NS="${PORCH_NS:-porch-demo}"
FLUX_NS="${FLUX_NS:-flux-system}"
GIT_SECRET="${GIT_SECRET:-gitea}"
KIND_CLUSTER="${KIND_CLUSTER:-porch-test}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
OTEL_JAVA_AGENT_VERSION="${OTEL_JAVA_AGENT_VERSION:-2.11.0}"
# Gitea backend
GIT_BASE="${GIT_BASE:-http://172.18.255.204:3000/porch}"   # <base>/<repo>.git (in-cluster LB IP)
GITEA_API="${GITEA_API:-http://172.18.255.204:3000/api/v1}"
GITEA_USER="${GITEA_USER:-porch}"
GITEA_PASS="${GITEA_PASS:-secret}"
# Back-compat alias (older code referenced GITLAB_BASE)
GITLAB_BASE="${GITLAB_BASE:-$GIT_BASE}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------------------------------------------------------------------------
# 1. build — build + kind-load branded images for a store type
# ---------------------------------------------------------------------------
# Image name -> source dir, per store. email is a special shared tag.
build_images() {
  local store="$1"
  require docker; require kind
  local base="$REPO_ROOT/$store"
  [[ -d "$base" ]] || die "no source dir for store '$store' at $base"

  log "Building '$store' images (tag :$IMAGE_TAG)"

  # name:dir:extra-build-args  (email builds to plain 'email:v1' for florist)
  declare -A imgs
  if [[ "$store" == "astronomy" ]]; then
    imgs=(
      ["astronomy-frontend"]="frontend"
      ["astronomy-ad"]="ad|--build-arg OTEL_JAVA_AGENT_VERSION=$OTEL_JAVA_AGENT_VERSION"
      ["astronomy-llm"]="llm"
      ["astronomy-email"]="email"
    )
  elif [[ "$store" == "florist" ]]; then
    imgs=(
      ["florist-frontend"]="frontend"
      ["florist-ad"]="ad|--build-arg OTEL_JAVA_AGENT_VERSION=$OTEL_JAVA_AGENT_VERSION"
      ["florist-llm"]="llm"
      ["florist-image-provider"]="image-provider"
      ["florist-load-generator"]="load-generator"
      ["email"]="email"
    )
  else
    die "unknown store '$store' (expected astronomy|florist)"
  fi

  for name in "${!imgs[@]}"; do
    local spec="${imgs[$name]}"
    local dir="${spec%%|*}"
    local args=""
    [[ "$spec" == *"|"* ]] && args="${spec#*|}"
    local ctx="$base/$dir"
    [[ -d "$ctx" ]] || { warn "skip $name: no dir $ctx"; continue; }
    log "  build $name:$IMAGE_TAG  (context: $store/$dir)"
    # shellcheck disable=SC2086
    docker build $args -t "$name:$IMAGE_TAG" "$ctx" >/dev/null
    log "  kind load $name:$IMAGE_TAG"
    kind load docker-image "$name:$IMAGE_TAG" --name "$KIND_CLUSTER" >/dev/null 2>&1
  done
  log "'$store' images built and loaded."
}

# ---------------------------------------------------------------------------
# porch helpers
# ---------------------------------------------------------------------------
p() { porchctl "$@" -n "$PORCH_NS"; }

latest_blueprint_rev() {  # latest_blueprint_rev [pkgname]
  local pkg="${1:-$BLUEPRINT_NAME}"
  porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
    | awk -v pkg="$pkg" '$2==pkg && $5=="true"{print $1}' | head -1
}

wait_lifecycle() {  # wait_lifecycle <pkgrev> <Draft|Proposed|Published>
  local pr="$1" want="$2" i
  for i in $(seq 1 30); do
    local lc
    lc="$(porchctl rpkg get "$pr" -n "$PORCH_NS" --no-headers 2>/dev/null | awk '{print $6}')"
    [[ "$lc" == "$want" ]] && return 0
    sleep 2
  done
  return 1
}

publish() {  # publish <pkgrev>
  local pr="$1"
  p rpkg propose "$pr" >/dev/null
  sleep 2
  p rpkg approve "$pr" >/dev/null
}

# Return the k8s name of an editable (Draft) revision of <repo>/<pkg>, creating one
# if needed. Echoes the pkgrev name.
#   mode=clone  -> if absent, `rpkg clone <src>`; src required
#   mode=init   -> if absent, `rpkg init`
# If a revision already exists: reuse it if Draft, else `rpkg copy` the latest
# published to a fresh workspace (you can't push to a Published revision).
editable_draft() {  # editable_draft <repo> <pkg> <clone|init> [src]
  local repo="$1" pkg="$2" mode="$3" src="${4:-}"
  # existing revisions of this repo/pkg
  local latest lc
  latest="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
            | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r && $5=="true"{print $1}' | head -1)"
  if [[ -z "$latest" ]]; then
    # nothing yet: create the first draft
    local pr="${repo}.${pkg}.v1"
    if [[ "$mode" == "clone" ]]; then
      p rpkg clone "$src" "$pkg" --repository="$repo" --workspace="v1" >/dev/null
    else
      p rpkg init "$pkg" --repository="$repo" --workspace="v1" --description="$pkg" >/dev/null
    fi
    wait_lifecycle "$pr" Draft >/dev/null 2>&1 || true
    echo "$pr"; return 0
  fi
  lc="$(porchctl rpkg get "$latest" -n "$PORCH_NS" --no-headers 2>/dev/null | awk '{print $6}')"
  if [[ "$lc" == "Draft" ]]; then
    echo "$latest"; return 0
  fi
  # latest is Published: copy to a new numeric workspace to get a Draft
  local maxn ws pr
  maxn="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
          | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r{print $3}' | sed 's/^v//' | grep -E '^[0-9]+$' | sort -n | tail -1)"
  ws="v$(( maxn + 1 ))"
  p rpkg copy "$latest" --workspace="$ws" >/dev/null
  pr="${repo}.${pkg}.${ws}"
  wait_lifecycle "$pr" Draft >/dev/null 2>&1 || true
  echo "$pr"
}

# Upgrade a published downstream package to the latest published revision of its
# upstream blueprint, via Porch's structural 3-way merge (resource-merge). Local
# per-clone customizations (namespace/region/branding/flux-config) are preserved.
# Echoes the new draft pkgrev, or empty if nothing to do.
upgrade_pkg() {  # upgrade_pkg <repo> <pkg> <blueprint-name>
  local repo="$1" pkg="$2" bpname="$3"
  # latest published downstream revision
  local latest; latest="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
      | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r && $5=="true"{print $1}' | head -1)"
  [[ -n "$latest" ]] || { warn "no published $pkg in $repo to upgrade"; return 1; }
  # target upstream blueprint revision number (numeric REVISION of latest blueprint)
  local bprev; bprev="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
      | awk -v p="$bpname" '$2==p && $5=="true"{print $4}' | head -1)"
  [[ -n "$bprev" ]] || { warn "no published $bpname"; return 1; }
  # next downstream workspace
  local maxn ws newpr
  maxn="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
      | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r{print $3}' | sed 's/^v//' | grep -E '^[0-9]+$' | sort -n | tail -1)"
  ws="v$(( maxn + 1 ))"
  newpr="${repo}.${pkg}.${ws}"
  log "  upgrade $latest -> $bpname rev $bprev (new $newpr)"
  p rpkg upgrade "$latest" --revision="$bprev" --workspace="$ws" >/dev/null 2>&1 || {
    warn "  rpkg upgrade failed (already latest?)"; return 1; }
  wait_lifecycle "$newpr" Draft >/dev/null 2>&1 || true
  echo "$newpr"
}

# Upgrade a region's app + flux packages to the latest blueprints and republish.
update_region() {  # update_region <region>
  local region; region="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  local ns="${region}-otel-demo"
  local apps_repo="${region}${APPS_SUFFIX}" flux_repo="${region}${FLUX_SUFFIX}"
  require porchctl
  log "Update region $region to latest blueprints"

  local apr; apr="$(upgrade_pkg "$apps_repo" "$PACKAGE_NAME" "$BLUEPRINT_NAME" || true)"
  [[ -n "$apr" ]] && publish "$apr" && log "  app upgraded + published: $apr"

  local fpr; fpr="$(upgrade_pkg "$flux_repo" "$FLUX_PKG_NAME" "$FLUX_BLUEPRINT_NAME" || true)"
  [[ -n "$fpr" ]] && publish "$fpr" && log "  flux upgraded + published: $fpr"

  # nudge Flux to pick up the new commits
  flux reconcile source git "${region}-flux" -n "$ns" --with-source >/dev/null 2>&1 || true
  flux reconcile kustomization "${region}-flux" -n "$ns" >/dev/null 2>&1 || true
  flux reconcile kustomization "$ns" -n "$ns" >/dev/null 2>&1 || true
  log "Update complete for $region"
}

# ---------------------------------------------------------------------------
# 2. blueprint — push a local blueprint dir to the blueprints repo and publish
# ---------------------------------------------------------------------------
publish_blueprint() {  # publish_blueprint <name> <dir> [subpkgs-to-wipe...]
  local name="$1" dir="$2"; shift 2
  local wipe=("$@")
  require porchctl
  [[ -f "$dir/Kptfile" ]] || die "no Kptfile at $dir"

  # Ensure prerequisites: git secret + the blueprints repo (Gitea + Porch, non-deployment).
  ensure_git_secret
  ensure_gitea_repo "$BLUEPRINT_REPO"
  ensure_repo_registered "$BLUEPRINT_REPO" "$BLUEPRINT_REPO" "/" false

  # No local `kpt fn render` (Porch renders server-side on push; a local render
  # would mutate the pristine source dir in place).
  local existing ws draft
  existing="$(latest_blueprint_rev "$name" || true)"
  if [[ -z "$existing" ]]; then
    ws="v1"
    log "Creating new blueprint $name/$ws in $BLUEPRINT_REPO"
    p rpkg init "$name" --repository="$BLUEPRINT_REPO" --workspace="$ws" \
        --description="$name" >/dev/null
    draft="${BLUEPRINT_REPO}.${name}.${ws}"
  else
    local maxn
    maxn="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
            | awk -v pkg="$name" '$2==pkg{print $4}' | grep -E '^[0-9]+$' | sort -n | tail -1)"
    ws="v$(( maxn + 1 ))"
    log "Copying $existing -> new workspace $ws"
    p rpkg copy "$existing" --workspace="$ws" >/dev/null
    draft="${BLUEPRINT_REPO}.${name}.${ws}"
  fi
  wait_lifecycle "$draft" Draft || warn "draft $draft not ready yet"

  local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
  log "Pulling draft metadata to $work"
  p rpkg pull "$draft" "$work" >/dev/null
  local d; for d in "${wipe[@]}"; do rm -rf "$work/$d"; done
  cp -r "$dir/." "$work/"
  log "Pushing package content to $draft (server-side render)"
  p rpkg push "$draft" "$work" >/dev/null
  publish "$draft"
  rm -rf "$tmp"
  log "Blueprint published: $draft"
}

# Publish the app blueprint (with its subpackages) — the 'blueprint' command.
push_blueprint() {
  publish_blueprint "$BLUEPRINT_NAME" "$BLUEPRINT_DIR" shop observability
}

# Publish the flux blueprint (no subpackages).
push_flux_blueprint() {
  publish_blueprint "$FLUX_BLUEPRINT_NAME" "$FLUX_BLUEPRINT_DIR"
}

# ---------------------------------------------------------------------------
# 3. deploy — clone blueprint into a region repo, set region + namespace (+ store),
#    publish, and register it in the Flux config package (GitOps).
# ---------------------------------------------------------------------------
deploy_target() {  # deploy_target <region> [store]
  local region_in="$1" store="${2:-astronomy}"
  local region; region="$(echo "$region_in" | tr '[:upper:]' '[:lower:]')"   # ireland
  local ns="${region}-otel-demo"                                             # ireland-otel-demo
  local apps_repo="${region}${APPS_SUFFIX}"                                  # ireland-apps
  local pkg="${PACKAGE_NAME}"                                                # gsoc-otel-demo
  require porchctl; require kubectl
  # Git auth secret must exist first (Porch reads repos, Flux fetches, and it gets
  # replicated onward). Create it from GITEA_USER/GITEA_PASS if missing.
  ensure_git_secret
  # Auto-publish blueprints if they don't exist yet (no error-out).
  local src; src="$(latest_blueprint_rev)"
  if [[ -z "$src" ]]; then
    log "App blueprint not published yet; publishing $BLUEPRINT_NAME"
    push_blueprint
    src="$(latest_blueprint_rev)"
  fi
  [[ -n "$src" ]] || die "failed to publish app blueprint"
  if [[ -z "$(latest_blueprint_rev "$FLUX_BLUEPRINT_NAME")" ]]; then
    log "Flux blueprint not published yet; publishing $FLUX_BLUEPRINT_NAME"
    push_flux_blueprint
  fi
  # Ensure Flux controllers + git secret exist (idempotent).
  kubectl get deploy kustomize-controller -n "$FLUX_NS" >/dev/null 2>&1 || flux_init

  log "Deploy: region=$region store=$store ns=$ns  apps-repo=$apps_repo  (from $src)"

  # Auto-create the backing Gitea repo + register the two Porch repos (both on <region>.git).
  ensure_gitea_repo "$region"
  ensure_repo_registered "$apps_repo" "$region" "/apps"
  ensure_repo_registered "${region}${FLUX_SUFFIX}" "$region" "/flux-config"

  # Resolve an editable Draft revision: clone if absent, else copy latest to a new
  # workspace (can't push to a Published revision).
  local pr; pr="$(editable_draft "$apps_repo" "$pkg" "clone" "$src")"

  # pull, set namespace + region + branding, push
  local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
  p rpkg pull "$pr" "$work" >/dev/null
  log "Setting namespace=$ns"
  cat > "$work/namespace-config.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: namespace-config
  annotations:
    config.kubernetes.io/local-config: "true"
data:
  namespace: $ns
EOF
  log "Setting region=$region"
  cat > "$work/regional/region-config.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: region-config
  annotations:
    config.kubernetes.io/local-config: "true"
data:
  region: $region
EOF
  if [[ -f "$work/branding/branding-config.yaml" ]]; then
    log "Setting storeType=$store"
    sed -i "s/storeType: .*/storeType: $store/" "$work/branding/branding-config.yaml"
  fi
  log "Pushing customized app package (server-side render)"
  p rpkg push "$pr" "$work" >/dev/null
  publish "$pr"
  rm -rf "$tmp"
  log "Published app package: $pr (in $apps_repo -> /apps)"

  # GitOps: publish the region's Flux wiring package into <region>-flux-config.
  add_flux_config "$region" "$ns"
  # Seed the per-region Flux root that watches <region>.git /flux-config.
  flux_bootstrap_region "$region"

  deploy_summary "$region" "$ns" "$store"
}

# Print a clean "deployment complete" summary with access instructions.
deploy_summary() {  # deploy_summary <region> <ns> <store>
  local region="$1" ns="$2" store="$3"
  cat >&2 <<EOF

$(printf '\033[1;32m')============================================================$(printf '\033[0m')
$(printf '\033[1;32m')  Deployment complete: $region ($store) -> namespace $ns$(printf '\033[0m')
$(printf '\033[1;32m')============================================================$(printf '\033[0m')

Flux is now reconciling the app from Git (GitOps). Give it a minute, then check:

  kubectl get pods -n $ns
  flux get kustomizations -n $ns

Access the store (port-forward blocks; run in its own terminal):

  kubectl port-forward -n $ns svc/frontend-proxy 8080:8080

Then open:
  Storefront   http://localhost:8080/
  Grafana      http://localhost:8080/grafana/     (503 until Grafana is Ready)
  Jaeger       http://localhost:8080/jaeger/ui/
  Feature UI   http://localhost:8080/feature/
  Load gen     http://localhost:8080/loadgen/

Tear down with:  $0 teardown $region
EOF
}

# Ensure the Porch namespace exists.
ensure_porch_ns() {
  require kubectl
  kubectl get ns "$PORCH_NS" >/dev/null 2>&1 || {
    log "Creating namespace $PORCH_NS"; kubectl create namespace "$PORCH_NS" >/dev/null; }
}

# Ensure the git auth Secret exists in the Porch namespace (source of truth that
# gets replicated into flux-system and each region namespace). Creates it from
# GITEA_USER/GITEA_PASS if missing.
ensure_git_secret() {
  require kubectl
  ensure_porch_ns
  if kubectl get secret "$GIT_SECRET" -n "$PORCH_NS" >/dev/null 2>&1; then
    return 0
  fi
  log "Creating git auth secret '$GIT_SECRET' in $PORCH_NS (user=$GITEA_USER)"
  kubectl create secret generic "$GIT_SECRET" -n "$PORCH_NS" \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$GITEA_USER" \
    --from-literal=password="$GITEA_PASS" >/dev/null
}

# Create the backing Gitea repo (auto-init with main branch) if it doesn't exist.
ensure_gitea_repo() {  # ensure_gitea_repo <repo>
  local repo="$1"
  if curl -s -o /dev/null -w '%{http_code}' -u "$GITEA_USER:$GITEA_PASS" \
       "$GITEA_API/repos/$GITEA_USER/$repo" 2>/dev/null | grep -q '^200$'; then
    return 0
  fi
  log "Creating Gitea repo $GITEA_USER/$repo"
  curl -s -o /dev/null -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_API/user/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$repo\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" 2>/dev/null || true
}

# Register a Gitea-backed Porch Repository if not already present.
ensure_repo_registered() {  # ensure_repo_registered <porch-name> <gitea-repo> <directory> [deployment]
  local name="$1" gitea_repo="$2" dir="$3" deployment="${4:-true}"
  if kubectl get repository "$name" -n "$PORCH_NS" >/dev/null 2>&1; then
    return 0
  fi
  log "Registering Porch repository '$name' -> $gitea_repo.git $dir (deployment=$deployment)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: config.porch.kpt.dev/v1alpha1
kind: Repository
metadata:
  name: $name
  namespace: $PORCH_NS
spec:
  description: $name
  content: Package
  deployment: $deployment
  type: git
  git:
    repo: $GIT_BASE/$gitea_repo.git
    directory: $dir
    branch: main
    createBranch: true
    secretRef:
      name: $GIT_SECRET
  sync:
    schedule: "0 2 * * *"
EOF
  local i
  for i in $(seq 1 20); do
    [[ "$(kubectl get repository "$name" -n "$PORCH_NS" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" == "True" ]] && { log "  repo $name ready"; return 0; }
    sleep 2
  done
  warn "  repo $name not Ready yet"
}

# ---------------------------------------------------------------------------
# Flux config as a Porch package (GitOps).
#   - flux-config package holds one GitRepository (the deployments repo) + one
#     Kustomization per deployment package.
#   - a single root Kustomization ('flux-bootstrap', created once) watches the
#     flux-config repo and applies whatever it finds.
#   Adding a deployment => add a Kustomization file to the flux-config package
#   as its own package (named <repo>) in the flux-config repo. A single root
#   Kustomization ('flux-bootstrap') watches the flux-config repo root and applies
#   every region package.  No imperative kubectl for wiring.
# ---------------------------------------------------------------------------

add_flux_config() {  # add_flux_config <region> <namespace>
  local region="$1" ns="$2"
  require porchctl
  local flux_repo="${region}${FLUX_SUFFIX}"          # ireland-flux-config
  local src; src="$(latest_blueprint_rev "$FLUX_BLUEPRINT_NAME")"
  [[ -n "$src" ]] || die "no published $FLUX_BLUEPRINT_NAME; run '$0 flux-blueprint' (or 'all')"

  log "GitOps: wiring $region -> $ns  ($flux_repo/$FLUX_PKG_NAME from $FLUX_BLUEPRINT_NAME)"
  local pr; pr="$(editable_draft "$flux_repo" "$FLUX_PKG_NAME" "clone" "$src")"

  local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
  p rpkg pull "$pr" "$work" >/dev/null
  # The Flux GitRepository points at the region Gitea repo; the app lives in /apps.
  cat > "$work/flux-config.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: flux-config
  annotations:
    config.kubernetes.io/local-config: "true"
data:
  repo: $region
  namespace: $ns
  appPath: apps
EOF
  p rpkg push "$pr" "$work" >/dev/null
  publish "$pr"
  rm -rf "$tmp"
  log "flux wiring package published: $pr (in $flux_repo -> /flux-config)"

  # nudge the region's root Kustomization to pick it up promptly (if bootstrap exists)
  flux reconcile kustomization "${region}-flux" -n "$ns" --with-source >/dev/null 2>&1 || true
}

# Per-region bootstrap: a root GitRepository + Kustomization that watches the
# region repo's /flux-config dir. That dir (published above) contains the region's
# Flux wiring, which in turn applies /apps. One seed per region.
flux_bootstrap_region() {  # flux_bootstrap_region <region>
  require flux; require kubectl
  local region; region="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  local ns="${region}-otel-demo"
  log "Bootstrapping Flux root for $region in ns $ns (watches $region.git /flux-config)"

  # The Flux objects live in the deployment namespace, so ensure it exists and
  # that source-controller can read the git secret from there.
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null 2>&1 || true
  if ! kubectl get secret "$GIT_SECRET" -n "$ns" >/dev/null 2>&1; then
    log "  replicating git secret $GIT_SECRET into $ns"
    kubectl get secret "$GIT_SECRET" -n "$PORCH_NS" -o yaml \
      | sed "s/namespace: $PORCH_NS/namespace: $ns/" \
      | grep -vE '^\s+(resourceVersion|uid|creationTimestamp|selfLink):' \
      | kubectl apply -n "$ns" -f - >/dev/null 2>&1 || true
  fi

  kubectl apply -f - >/dev/null <<EOF
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: ${region}-flux
  namespace: $ns
spec:
  interval: 1m
  url: $GIT_BASE/${region}.git
  ref:
    branch: main
  secretRef:
    name: $GIT_SECRET
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ${region}-flux
  namespace: $ns
spec:
  interval: 2m
  retryInterval: 1m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: ${region}-flux
  path: ./flux-config
  prune: true
  wait: false
EOF
  flux reconcile source git "${region}-flux" -n "$ns" >/dev/null 2>&1 || true
  flux reconcile kustomization "${region}-flux" -n "$ns" >/dev/null 2>&1 || true
}

# Global bootstrap: install Flux + secret, and ensure the flux blueprint is
# published (each region clones it). Per-region roots are created during deploy
# via flux_bootstrap_region.
flux_bootstrap() {
  require flux; require kubectl
  flux_init
  [[ -n "$(latest_blueprint_rev "$FLUX_BLUEPRINT_NAME")" ]] || push_flux_blueprint
  log "Global bootstrap complete (Flux installed, secret + flux-blueprint ready)."
}


# ---------------------------------------------------------------------------
# 4. flux-init — install Flux + replicate git auth secret
# ---------------------------------------------------------------------------
flux_init() {
  require flux; require kubectl
  ensure_git_secret   # make sure the source secret in $PORCH_NS exists before replicating
  if kubectl get deploy -n "$FLUX_NS" kustomize-controller >/dev/null 2>&1; then
    log "Flux already installed"
  else
    log "Installing Flux controllers"
    flux install >/dev/null
  fi
  if ! kubectl get secret "$GIT_SECRET" -n "$FLUX_NS" >/dev/null 2>&1; then
    log "Replicating git secret $GIT_SECRET into $FLUX_NS"
    kubectl get secret "$GIT_SECRET" -n "$PORCH_NS" -o yaml \
      | sed "s/namespace: $PORCH_NS/namespace: $FLUX_NS/" \
      | grep -vE '^\s+(resourceVersion|uid|creationTimestamp|selfLink):' \
      | kubectl apply -n "$FLUX_NS" -f - >/dev/null
  else
    log "git secret already present in $FLUX_NS"
  fi
}

# ---------------------------------------------------------------------------
# status / usage
# ---------------------------------------------------------------------------
status() {
  echo "== Blueprints =="
  porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
    | awk -v a="$BLUEPRINT_NAME" -v b="$FLUX_BLUEPRINT_NAME" 'NR==1 || (($2==a||$2==b) && $5=="true")'
  echo; echo "== App packages (per <region>-apps repo, latest) =="
  porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
    | awk -v p="$PACKAGE_NAME" 'NR==1 || ($2==p && $5=="true")'
  echo; echo "== Flux wiring packages (per <region>-flux-config repo, latest) =="
  porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
    | awk -v p="$FLUX_PKG_NAME" 'NR==1 || ($2==p && $5=="true")'
  echo; echo "== Flux kustomizations =="
  flux get kustomizations -n "$FLUX_NS" 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Everything is automated — deploying a region will, as needed, create the git
secret, Gitea repos, publish the blueprints, install Flux, and register the Porch
repos. In most cases you only need the commands in the first group.

Commands:
  <region> [store]     Deploy a region end-to-end (store: astronomy|florist, default astronomy).
                       e.g.  $0 ireland   |   $0 sweden florist
  all                  Build images + deploy all three regions (ireland, sweden, hungary)
  status               Show blueprints, app + flux packages, and Flux status
  teardown <region>    Tear down one region (Flux root, Porch packages, namespace, RBAC)
  teardown --all       Tear down all regions.  Flags: --blueprint --flux --images

Update (roll a region forward after editing/republishing a blueprint):
  update <region>      Upgrade a region's app + flux packages to the latest blueprints
                       (Porch resource-merge, preserves region customizations), then reconcile
  update-all           update ireland + sweden + hungary

Other:
  build <astronomy|florist>   (Re)build + kind-load the branded images for a store

Advanced (normally run automatically by a deploy — rarely needed directly):
  blueprint            Publish local app-blueprint/ to '$BLUEPRINT_REPO'
  flux-blueprint       Publish local flux-blueprint/ to '$BLUEPRINT_REPO'
  flux-init            Install Flux controllers + create/replicate the git secret
  flux-bootstrap       flux-init + ensure the flux blueprint is published

GitOps model: per region there is ONE Gitea repo with two dirs — /apps (the shop,
from app-blueprint) and /flux-config (the Flux wiring, from flux-blueprint), each a
Porch package. A per-region root Kustomization (<region>-flux) watches /flux-config,
which applies /apps. Adding/updating a region = republish its packages via Porch.

Regions: ireland (en-IE/EUR), sweden (sv-SE/SEK), hungary (hu-HU/HUF),
         plus us, india, czech-republic, china.

Env overrides: BLUEPRINT_DIR, FLUX_BLUEPRINT_DIR, PORCH_NS ($PORCH_NS),
  BLUEPRINT_REPO ($BLUEPRINT_REPO), APPS_SUFFIX ($APPS_SUFFIX), FLUX_SUFFIX ($FLUX_SUFFIX),
  GIT_BASE ($GIT_BASE), GIT_SECRET ($GIT_SECRET), KIND_CLUSTER ($KIND_CLUSTER).

Examples:
  $0 ireland                       # deploy ireland (astronomy)
  $0 sweden florist                # deploy sweden as a florist store
  $0 all                           # deploy all three regions
  $0 update ireland                # roll ireland forward to the latest blueprints
  $0 teardown ireland              # tear down one region
  $0 teardown --all --blueprint --flux   # tear down everything
EOF
}

# ---------------------------------------------------------------------------
# teardown — reverse a deploy (Flux resources, Porch package revisions, namespace)
# ---------------------------------------------------------------------------
delete_porch_pkg_revisions() {  # delete all revisions of PACKAGE_NAME in <repo>
  local repo="$1"
  # Delete non-'main' revisions first, then the 'main' aggregate, to avoid dependency errors.
  local names
  names="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
           | awk -v r="$repo" -v p="$PACKAGE_NAME" '$2==p && $7==r {print $1}')"
  [[ -z "$names" ]] && { warn "no $PACKAGE_NAME revisions in $repo"; return 0; }
  # published revisions require propose-delete before delete; drafts delete directly.
  for n in $(echo "$names" | grep -v '\.main$'); do
    porchctl rpkg propose-delete "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    porchctl rpkg del "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    log "  deleted package revision $n"
  done
  for n in $(echo "$names" | grep '\.main$'); do
    porchctl rpkg propose-delete "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    porchctl rpkg del "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    log "  deleted package revision $n"
  done
}

delete_porch_pkg_revisions() {  # delete all revisions of <pkg> in <repo>
  local repo="$1" pkg="$2"
  local names
  names="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
           | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r {print $1}')"
  [[ -z "$names" ]] && { warn "no $pkg revisions in $repo"; return 0; }
  for n in $(echo "$names" | grep -v '\.main$'); do
    porchctl rpkg propose-delete "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    porchctl rpkg del "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    log "  deleted package revision $n"
  done
  for n in $(echo "$names" | grep '\.main$'); do
    porchctl rpkg propose-delete "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    porchctl rpkg del "$n" -n "$PORCH_NS" >/dev/null 2>&1 || true
    log "  deleted package revision $n"
  done
}

teardown_target() {  # teardown_target <repo>
  local region_in="$1"
  local region; region="$(echo "$region_in" | tr '[:upper:]' '[:lower:]')"
  local ns="${region}-otel-demo"
  local apps_repo="${region}${APPS_SUFFIX}"
  local flux_repo="${region}${FLUX_SUFFIX}"
  require kubectl; require porchctl
  log "Teardown: region=$region ns=$ns"

  # 1. Delete the per-region Flux root (GitRepository + Kustomization <region>-flux).
  #    Its prune:true garbage-collects the inner Flux wiring, which in turn (prune:true)
  #    removes the applied workloads + namespace.
  log "  deleting Flux root ${region}-flux (prunes wiring + workloads)"
  kubectl delete kustomization "${region}-flux" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete gitrepository "${region}-flux" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  sleep 5

  # 2. Delete the Porch packages: flux wiring (in <region>-flux-config) and app (in <region>-apps).
  log "  deleting Porch package $FLUX_PKG_NAME in $flux_repo"
  delete_porch_pkg_revisions "$flux_repo" "$FLUX_PKG_NAME"
  log "  deleting Porch package $PACKAGE_NAME in $apps_repo"
  delete_porch_pkg_revisions "$apps_repo" "$PACKAGE_NAME"

  # 3. Delete the namespace (belt-and-suspenders) + namespace-prefixed cluster RBAC.
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    log "  deleting namespace $ns"
    kubectl delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  log "  deleting cluster-scoped RBAC prefixed with $ns-"
  for kind in clusterrole clusterrolebinding; do
    for r in $(kubectl get "$kind" -o name 2>/dev/null | grep "/${ns}-" || true); do
      kubectl delete "$r" --ignore-not-found >/dev/null 2>&1 || true
    done
  done
  log "Teardown complete for $region"
}

delete_blueprint() {
  require porchctl
  log "Deleting blueprint revisions in $BLUEPRINT_REPO ($BLUEPRINT_NAME, $FLUX_BLUEPRINT_NAME)"
  delete_porch_pkg_revisions "$BLUEPRINT_REPO" "$BLUEPRINT_NAME"
  delete_porch_pkg_revisions "$BLUEPRINT_REPO" "$FLUX_BLUEPRINT_NAME"
}

uninstall_flux() {
  require flux
  warn "Uninstalling Flux controllers from the cluster"
  flux uninstall --silent >/dev/null 2>&1 || true
  log "Flux uninstalled"
}

remove_images() {
  require docker
  log "Removing built branded images (tag :$IMAGE_TAG)"
  for img in astronomy-frontend astronomy-ad astronomy-llm astronomy-email \
             florist-frontend florist-ad florist-llm florist-image-provider \
             florist-load-generator email; do
    docker rmi "$img:$IMAGE_TAG" >/dev/null 2>&1 && log "  removed $img:$IMAGE_TAG" || true
  done
}



# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  build)      [[ $# -eq 1 ]] || die "usage: $0 build <astronomy|florist>"; build_images "$1" ;;
  blueprint)  push_blueprint ;;
  flux-blueprint) push_flux_blueprint ;;
  deploy)     [[ $# -ge 1 ]] || die "usage: $0 deploy <region> [store]"; deploy_target "$@" ;;
  flux-init)  flux_init ;;
  flux-bootstrap) flux_bootstrap ;;
  status)     status ;;
  update)     [[ $# -ge 1 ]] || die "usage: $0 update <region>"; update_region "$1" ;;
  update-all)
    update_region ireland
    update_region sweden
    update_region hungary
    log "Update-all complete."
    ;;
  teardown)
    [[ $# -ge 1 ]] || die "usage: $0 teardown <region>  (or: $0 teardown-all)"
    if [[ "$1" == --all || "$1" == all ]]; then
      shift
      teardown_target ireland; teardown_target sweden; teardown_target hungary
      for arg in "$@"; do
        case "$arg" in
          --blueprint) delete_blueprint ;;
          --flux)      uninstall_flux ;;
          --images)    remove_images ;;
          *) warn "unknown teardown flag: $arg" ;;
        esac
      done
      log "Teardown-all complete."
    else
      case "$1" in
        -*) die "'$1' is not a region. Use: $0 teardown <region>  or  $0 teardown-all [--blueprint --flux --images]" ;;
      esac
      teardown_target "$1"
    fi
    ;;
  teardown-all)
    teardown_target ireland
    teardown_target sweden
    teardown_target hungary
    for arg in "$@"; do
      case "$arg" in
        --blueprint) delete_blueprint ;;
        --flux)      uninstall_flux ;;
        --images)    remove_images ;;
        *) warn "unknown teardown-all flag: $arg" ;;
      esac
    done
    log "Teardown-all complete."
    ;;
  all)
    build_images astronomy
    push_blueprint
    flux_bootstrap
    deploy_target ireland
    deploy_target sweden
    deploy_target hungary
    log "Done. Run '$0 status' and port-forward svc/frontend-proxy to view."
    ;;
  ""|-h|--help|help) usage ;;
  -*) die "unknown option '$cmd' (run '$0 help')" ;;
  *)
    # Fallback: treat an unrecognized first arg as a region to deploy, so you can
    # write `./deploy.sh ireland` or `./deploy.sh ireland florist`.
    deploy_target "$cmd" "$@"
    ;;
esac
