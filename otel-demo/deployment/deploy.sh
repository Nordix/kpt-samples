#!/usr/bin/env bash
#
# deploy.sh — Automate the otel-demo Porch + Flux deployment.
#
# Pipeline it automates (the manual flow, scripted):
#   1. images     Branded images are pre-published to a registry
#                 (ghcr.io/kptdev/kpt-samples/otel-demo/*) and pulled by the
#                 workload clusters. Building + kind-loading them locally is
#                 optional (`build` command, or BUILD_LOCAL=1 during a deploy).
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
# Requires: kubectl, kpt, porchctl, flux, kind (region workload clusters), python3.
#           docker is needed only for the optional 'images' check and local 'build'.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # the deployment/ folder (where this script lives)
BLUEPRINT_DIR="${BLUEPRINT_DIR:-$REPO_ROOT/app-blueprint}"
FLUX_BLUEPRINT_DIR="${FLUX_BLUEPRINT_DIR:-$REPO_ROOT/flux-blueprint}"
PACKAGE_NAME="${PACKAGE_NAME:-otel-demo}"          # app package name inside <region>-apps repo
FLUX_PKG_NAME="${FLUX_PKG_NAME:-flux}"                  # flux package name inside <region>-flux-config repo
BLUEPRINT_NAME="${BLUEPRINT_NAME:-otel-demo-blueprint}"
FLUX_BLUEPRINT_NAME="${FLUX_BLUEPRINT_NAME:-flux-blueprint}"  # published flux blueprint pkg name
# BLUEPRINT_REPO is resolved at runtime by resolve_blueprint_repo (called from
# main after the backend is known): if a blueprints repo already exists it is
# REUSED as-is (any backend); otherwise a new one is created, named 'blueprints'
# for gitea and 'blueprints-gitlab' for gitlab so the two never collide. An
# explicit BLUEPRINT_REPO env var always wins and skips resolution.
BLUEPRINT_REPO_EXPLICIT="${BLUEPRINT_REPO:+1}"   # set if user pinned it via env
BLUEPRINT_REPO="${BLUEPRINT_REPO:-blueprints}"   # provisional default; may be re-resolved
# Per region there are two Porch repos backed by one Gitea repo (different dirs):
#   <region>-apps         -> /apps         (the shop app package)
#   <region>-flux-config  -> /flux-config  (the Flux wiring package)
APPS_SUFFIX="${APPS_SUFFIX:--apps}"
FLUX_SUFFIX="${FLUX_SUFFIX:--flux-config}"
PORCH_NS="${PORCH_NS:-porch-demo}"
FLUX_NS="${FLUX_NS:-flux-system}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
OTEL_JAVA_AGENT_VERSION="${OTEL_JAVA_AGENT_VERSION:-2.11.0}"
# --- Multi-cluster: this (management) cluster runs Porch + Flux; each region gets
#     its own kind cluster that Flux applies to remotely via a kubeconfig Secret. ---
MGMT_CLUSTER="${MGMT_CLUSTER:-porch-test}"        # kind name of the management cluster
MGMT_CONTEXT="${MGMT_CONTEXT:-kind-${MGMT_CLUSTER}}"
REGION_CLUSTER_PREFIX="${REGION_CLUSTER_PREFIX:-}"  # region kind cluster = <prefix><region>
KIND_CLUSTER="${KIND_CLUSTER:-$MGMT_CLUSTER}"      # back-compat alias

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ---------------------------------------------------------------------------
# Git backend (Gitea by default; GitLab opt-in via `--gitBackend gitlab`).
# ---------------------------------------------------------------------------
# Porch talks to a git server to store package revisions. Two backends are
# supported and differ in three ways:
#   1. the Porch Repository `type:` field  (git for Gitea, gitlab for GitLab)
#   2. the git base URL / API used to auto-create backing repos
#   3. the auth secret + credentials
#
# GIT_BACKEND selects which one. It defaults to "gitea" and is overridden by the
# `--gitBackend <gitea|gitlab>` global flag (parsed in main, which then calls
# apply_git_backend to set the effective GIT_* values below).
# Set to 1 when the user explicitly selects a backend (env GIT_BACKEND, or the
# --gitBackend flag which sets it in the arg parser). Captured BEFORE the default
# is applied so auto-detection can defer to an explicit choice.
GIT_BACKEND_EXPLICIT="${GIT_BACKEND:+1}"; GIT_BACKEND_EXPLICIT="${GIT_BACKEND_EXPLICIT:-0}"
GIT_BACKEND="${GIT_BACKEND:-gitea}"

# --- Gitea backend defaults ---
GITEA_BASE="${GITEA_BASE:-http://172.18.255.204:3000/porch}"   # <base>/<repo>.git (in-cluster LB IP)
GITEA_API="${GITEA_API:-http://172.18.255.204:3000/api/v1}"
GITEA_USER="${GITEA_USER:-porch}"
GITEA_PASS="${GITEA_PASS:-secret}"
GITEA_SECRET="${GITEA_SECRET:-gitea}"

# --- GitLab backend defaults (see ~/work/repo/v1alpha1/gitlab/*.yaml) ---
# GitLab exposes git over its web port; repos live under <base>/<repo>.git and
# are created via the GitLab REST API (v4).
#
# IMPORTANT: GitLab does NOT accept an account password over HTTP Basic for git
# or the API — it requires a Personal Access Token (PAT) with 'read_repository'
# and 'write_repository' scope (api scope too, for repo auto-creation). There is
# no usable default, so GITLAB_PASS/GITLAB_TOKEN must be provided by the user; a
# gitlab deploy fails fast (in ensure_git_secret) if it's empty.
GITLAB_BASE="${GITLAB_BASE:-http://172.18.0.100:8929/porch}"   # <base>/<repo>.git
GITLAB_API="${GITLAB_API:-http://172.18.0.100:8929/api/v4}"
GITLAB_USER="${GITLAB_USER:-porch}"
# Token precedence (matches loadTest/suite.sh): GITLAB_TOKEN > GIT_TOKEN > GITLAB_PASS.
# No bogus default — GitLab requires a real PAT and we fail fast if it's empty.
GITLAB_PASS="${GITLAB_TOKEN:-${GIT_TOKEN:-${GITLAB_PASS:-}}}"   # GitLab Personal Access Token (PAT)
GITLAB_SECRET="${GITLAB_SECRET:-gitlab-local}"
# Auto-provisioning (mirrors loadTest/env/local.env): when the gitlab backend is
# selected and no token was supplied, deploy.sh will reuse a cached token, and if
# none is valid, mint a full-scope PAT from the running GitLab container's Rails
# console and cache it. The token is cached in the deployment folder next to this
# script (.gitlab-token) — override the path with GIT_TOKEN_CACHE if needed.
GITLAB_CONTAINER="${GITLAB_CONTAINER:-gitlab}"
# Cache the provisioned token inside the deployment folder (next to this script).
GITLAB_TOKEN_CACHE="${GIT_TOKEN_CACHE:-$SCRIPT_DIR/.gitlab-token}"
GITLAB_TOKEN_NAME="${GITLAB_TOKEN_NAME:-loadtest-suite}"   # PAT name reused in gitlab

# --- GitLab SCM webhook (Porch merge-request receiver) ---
# For type=gitlab, Porch reacts to merged MRs via an SCM webhook. Each region's
# GitLab project needs a webhook pointing at Porch's receiver, carrying the shared
# X-Gitlab-Token. deploy.sh registers it (idempotently) after creating the project,
# resolving the target live from the cluster (ported from loadTest/gitlab/add-webhooks.sh):
#   - target IP/port <- LoadBalancer service $WEBHOOK_LB_SVC in $WEBHOOK_NS
#   - token          <- Secret $WEBHOOK_SECRET (key 'token') in $WEBHOOK_NS
# The token secret is auto-created (random value) if missing, and porch-server is
# restarted so it picks up PORCH_SCM_WEBHOOK_TOKEN (env-from-secret, read at start).
# Set WEBHOOK_REGISTER=0 to skip the whole webhook step.
WEBHOOK_REGISTER="${WEBHOOK_REGISTER:-1}"
WEBHOOK_NS="${WEBHOOK_NS:-porch-system}"          # ns of the webhook LB service + token secret
WEBHOOK_LB_SVC="${WEBHOOK_LB_SVC:-porch-webhook-lb}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-porch-scm-webhook}"  # k8s secret holding the shared token (key: token)
WEBHOOK_SERVER_DEPLOY="${WEBHOOK_SERVER_DEPLOY:-porch-server}"  # deploy reading PORCH_SCM_WEBHOOK_TOKEN
WEBHOOK_PATH="${WEBHOOK_PATH:-/scm/webhook}"
WEBHOOK_IP="${WEBHOOK_IP:-}"                       # override LB IP (else read from service)
WEBHOOK_PORT="${WEBHOOK_PORT:-}"                   # override port (else read from service)
WEBHOOK_TOKEN="${WEBHOOK_TOKEN:-}"                 # override token (else read from secret)

# Capture any env-provided GIT_SECRET ONCE. If the user exported GIT_SECRET it
# wins for whichever backend is selected; otherwise each backend falls back to
# its own default secret name. Captured here (before apply_git_backend ever runs)
# so that re-invoking apply_git_backend after a backend switch doesn't mistake a
# previously-derived default for a user override.
_GIT_SECRET_ENV="${GIT_SECRET:-}"

# apply_git_backend — resolve the effective GIT_* values from the selected
# backend. Called once after global flag parsing (and safe to call again if
# GIT_BACKEND changes). Sets:
#   GIT_BASE    git URL base (<base>/<repo>.git)
#   GIT_API     REST API base used to auto-create repos
#   GIT_USER    / GIT_PASS  credentials
#   GIT_SECRET  k8s secret name holding the credentials
#   GIT_TYPE    Porch Repository `type:` (git | gitlab)
apply_git_backend() {
  case "$GIT_BACKEND" in
    gitea)
      GIT_BASE="${GITEA_BASE}"
      GIT_API="${GITEA_API}"
      GIT_USER="${GITEA_USER}"
      GIT_PASS="${GITEA_PASS}"
      GIT_SECRET="${_GIT_SECRET_ENV:-$GITEA_SECRET}"
      GIT_TYPE="git"
      ;;
    gitlab)
      GIT_BASE="${GITLAB_BASE}"
      GIT_API="${GITLAB_API}"
      GIT_USER="${GITLAB_USER}"
      GIT_PASS="${GITLAB_PASS}"
      GIT_SECRET="${_GIT_SECRET_ENV:-$GITLAB_SECRET}"
      GIT_TYPE="gitlab"
      ;;
    *)
      die "invalid --gitBackend '$GIT_BACKEND' — must be 'gitea' or 'gitlab'"
      ;;
  esac
}
# Note: if GIT_SECRET is exported in the env it wins for both backends; otherwise
# each backend's default secret name is used. Resolve the initial defaults now so
# functions referencing GIT_* before flag parsing still work; main re-applies
# after parsing --gitBackend.
apply_git_backend

# --- GitLab token auto-provisioning (mirrors loadTest/env/local.env) ---------
# Returns 0 if <token> authenticates against the GitLab API (/api/v4/user).
_gitlab_token_valid() {  # _gitlab_token_valid <token>
  local tok="$1" code
  [[ -z "$tok" ]] && return 1
  code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 \
    "$GITLAB_API/user" -H "PRIVATE-TOKEN: $tok" 2>/dev/null || echo 000)
  [[ "$code" == "200" ]]
}

# Mint a fresh full-scope PAT for $GITLAB_USER via the gitlab container's Rails
# console (idempotent: reuses/reissues a token named $GITLAB_TOKEN_NAME). Echoes
# the plaintext token, or nothing on failure.
_gitlab_provision_token() {
  docker exec "$GITLAB_CONTAINER" gitlab-rails runner '
    u = User.find_by(username: "'"${GITLAB_USER}"'")
    raise "user not found" unless u
    name = "'"${GITLAB_TOKEN_NAME}"'"
    t = u.personal_access_tokens.find_by(name: name) || u.personal_access_tokens.new(name: name)
    t.scopes = Gitlab::Auth.all_available_scopes.map(&:to_s)
    t.expires_at = 365.days.from_now
    t.revoked = false
    plain = "glpat-loadtest" + SecureRandom.hex(10)
    t.set_token(plain); t.save!
    puts "TOKEN=#{plain}"
  ' 2>/dev/null | grep -oE 'glpat-[A-Za-z0-9]+' | head -1
}

# ensure_gitlab_token — resolve a usable GitLab PAT into GIT_PASS, provisioning
# one if needed. Order (matches the load-test suite):
#   1. If GIT_PASS is already a valid token, keep it (and refresh the cache).
#   2. Else reuse the cached token if it still authenticates.
#   3. Else mint a new one from the running gitlab container and cache it.
# No-op unless the gitlab backend is selected. Leaves GIT_PASS empty on failure
# (ensure_git_secret then fails fast with guidance).
ensure_gitlab_token() {
  [[ "$GIT_BACKEND" == "gitlab" ]] || return 0

  # 1. A token the user already supplied (env) that works — cache and use it.
  if [[ -n "$GIT_PASS" ]] && _gitlab_token_valid "$GIT_PASS"; then
    mkdir -p "$(dirname "$GITLAB_TOKEN_CACHE")" 2>/dev/null || true
    ( umask 077; printf '%s' "$GIT_PASS" > "$GITLAB_TOKEN_CACHE" ) 2>/dev/null || true
    return 0
  fi
  # If a token was supplied but is invalid, warn (don't silently replace an
  # explicit choice unless we can do better below).
  [[ -n "$GIT_PASS" ]] && warn "provided GitLab token failed authentication; trying cache/auto-provision"

  # 2. Cached token (in the deployment folder: $GITLAB_TOKEN_CACHE).
  if [[ -f "$GITLAB_TOKEN_CACHE" ]]; then
    local cached; cached="$(cat "$GITLAB_TOKEN_CACHE" 2>/dev/null || true)"
    if _gitlab_token_valid "$cached"; then
      GIT_PASS="$cached"; GITLAB_PASS="$cached"
      log "GitLab token reused from cache (${GIT_PASS:0:12}...)"
      return 0
    fi
  fi

  # 3. Mint a new one from the running gitlab container.
  if command -v docker >/dev/null 2>&1 \
     && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$GITLAB_CONTAINER"; then
    log "Provisioning GitLab token from container '$GITLAB_CONTAINER' (may take ~1 min)..."
    local minted; minted="$(_gitlab_provision_token || true)"
    if [[ -n "$minted" ]] && _gitlab_token_valid "$minted"; then
      GIT_PASS="$minted"; GITLAB_PASS="$minted"
      mkdir -p "$(dirname "$GITLAB_TOKEN_CACHE")" 2>/dev/null || true
      ( umask 077; printf '%s' "$minted" > "$GITLAB_TOKEN_CACHE" ) 2>/dev/null || true
      log "GitLab token provisioned + cached (${GIT_PASS:0:12}...)"
      return 0
    fi
    warn "GitLab token auto-provisioning failed (Rails console returned no usable token)"
  else
    warn "GitLab container '$GITLAB_CONTAINER' not running; cannot auto-provision a token (set GITLAB_TOKEN or GITLAB_CONTAINER)"
  fi
  return 0   # leave GIT_PASS as-is; ensure_git_secret enforces non-empty
}
# -----------------------------------------------------------------------------


# assert_repo_backend — validate that an existing Porch Repository matches the
# SELECTED backend, and die early (before any side-effecting work) if it was
# created on a different one. No-op if the repo doesn't exist yet or already
# matches. Used to catch "deployed on gitea, now trying gitlab" up front.
#   assert_repo_backend <porch-name> <git-repo>
assert_repo_backend() {
  local name="$1" git_repo="$2"
  kubectl get repository "$name" -n "$PORCH_NS" >/dev/null 2>&1 || return 0
  local existing_type existing_repo
  existing_type="$(kubectl get repository "$name" -n "$PORCH_NS" -o jsonpath='{.spec.type}' 2>/dev/null)"
  existing_repo="$(kubectl get repository "$name" -n "$PORCH_NS" -o jsonpath='{.spec.git.repo}' 2>/dev/null)"
  [[ "$existing_type" == "$GIT_TYPE" && "$existing_repo" == "$GIT_BASE/$git_repo.git" ]] && return 0
  die "Porch repository '$name' is already registered on a different git backend"$'\n'\
"       existing : type=$existing_type  repo=$existing_repo"$'\n'\
"       requested: type=$GIT_TYPE  repo=$GIT_BASE/$git_repo.git  (--gitBackend $GIT_BACKEND)"$'\n'\
"       This was already deployed with a different git backend. Tear it down first,"$'\n'\
"       then re-deploy on '$GIT_BACKEND':"$'\n'\
"           $0 teardown ${name%%-*}        # e.g. '$0 teardown ireland'"
}

# resolve_blueprint_repo — decide which git repo the shared blueprints live in,
# based on what already exists (reuse) or, if nothing exists, the current backend
# (create with a backend-appropriate name so gitea/gitlab never collide).
#
# Rules:
#   1. If the user pinned BLUEPRINT_REPO via env, honor it verbatim.
#   2. Else if a Porch Repository already hosts the blueprint package (any
#      backend/name), REUSE that repo — blueprints are backend-agnostic and are
#      cloned via Porch, so a region on gitlab can clone blueprints on gitea.
#   3. Else if a Repository literally named 'blueprints' exists, reuse it.
#   4. Else create a fresh one: 'blueprints' for gitea, 'blueprints-gitlab' for
#      gitlab (backend-suffixed so the two backends' blueprint repos don't clash).
# Sets BLUEPRINT_REPO. Safe to call once per run (from main, after apply_git_backend).
resolve_blueprint_repo() {
  [[ "${BLUEPRINT_REPO_EXPLICIT:-}" == "1" ]] && return 0   # rule 1: user override wins
  command -v porchctl >/dev/null 2>&1 || { BLUEPRINT_REPO="blueprints"; return 0; }

  # rule 2: repo (column 7) that already holds a published BLUEPRINT_NAME revision.
  # Capture porchctl output into a variable FIRST, then filter — piping porchctl
  # directly into `awk ... exit` (or head) closes the pipe early and SIGPIPEs
  # porchctl, which under `set -o pipefail` aborts the whole script (exit 141).
  local rpkg_out existing_repo
  rpkg_out="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null || true)"
  existing_repo="$(printf '%s\n' "$rpkg_out" \
      | awk -v p="$BLUEPRINT_NAME" '$2==p && $5=="true"{print $7}' | head -1 || true)"
  if [[ -n "$existing_repo" ]]; then
    BLUEPRINT_REPO="$existing_repo"
    return 0
  fi

  # rule 3: a Repository literally named 'blueprints' already registered.
  if kubectl get repository "blueprints" -n "$PORCH_NS" >/dev/null 2>&1; then
    BLUEPRINT_REPO="blueprints"
    return 0
  fi

  # rule 4: nothing exists yet — pick a backend-appropriate NEW name.
  case "$GIT_BACKEND" in
    gitlab) BLUEPRINT_REPO="blueprints-gitlab" ;;
    *)      BLUEPRINT_REPO="blueprints" ;;
  esac
}

# detect_region_backend — infer a region's git backend from its already-registered
# <region>-apps Porch Repository (spec.type) and switch GIT_BACKEND to match, so
# deploy/upgrade operate on the backend the region actually lives on (correct
# blueprints repo, publish/MR flow, and git secret) WITHOUT requiring --gitBackend.
# Defers to an explicit user choice (GIT_BACKEND_EXPLICIT=1) and to a region that
# isn't registered yet (nothing to detect — keep the current/selected backend).
detect_region_backend() {  # detect_region_backend <region>
  [[ "${GIT_BACKEND_EXPLICIT:-0}" == "1" ]] && return 0   # user pinned it; honor
  command -v kubectl >/dev/null 2>&1 || return 0
  local region="$1" apps_repo="${1}${APPS_SUFFIX}" t detected
  t="$(kubectl get repository "$apps_repo" -n "$PORCH_NS" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  [[ -n "$t" ]] || return 0   # region not registered yet — nothing to detect
  case "$t" in
    gitlab) detected="gitlab" ;;
    git)    detected="gitea"  ;;
    *)      return 0 ;;
  esac
  if [[ "$detected" != "$GIT_BACKEND" ]]; then
    log "Detected region '$region' is on '$detected' backend (repo $apps_repo type=$t); switching from '$GIT_BACKEND'"
    GIT_BACKEND="$detected"
    apply_git_backend
    # For gitlab, resolve a usable token now so publish/secret steps work.
    [[ "$GIT_BACKEND" == "gitlab" ]] && ensure_gitlab_token
  fi
}

# ---------------------------------------------------------------------------
# Interactive / educational mode
# ---------------------------------------------------------------------------
# Turn the deploy into a guided walkthrough that explains what KPT & Porch are
# doing at each stage and shows what changes (package lifecycle, KRM diffs, git,
# Flux state). Opt-in — the script behaves exactly as before unless enabled.
#
#   INTERACTIVE=1                enable narration + pauses (or pass --interactive / -i)
#   AUTO=1                       narrate but don't wait for Enter (auto-advance with a
#                                short delay — good for recorded/hands-free demos)
#   STEP_DELAY=<seconds>         delay between auto-advanced steps (default 2)
#
INTERACTIVE="${INTERACTIVE:-0}"
AUTO="${AUTO:-0}"
STEP_DELAY="${STEP_DELAY:-2}"
_STEP_NO=0

# ANSI helpers (only colorize when writing to a TTY).
if [[ -t 2 ]]; then
  _C_STEP=$'\033[1;36m'; _C_EXPLAIN=$'\033[0;36m'; _C_CMD=$'\033[1;35m'
  _C_KEY=$'\033[1;33m'; _C_DIM=$'\033[2m'; _C_RST=$'\033[0m'
else
  _C_STEP=''; _C_EXPLAIN=''; _C_CMD=''; _C_KEY=''; _C_DIM=''; _C_RST=''
fi

interactive() { [[ "$INTERACTIVE" == "1" ]]; }

# step <title> — announce a numbered stage banner (only in interactive mode).
step() {
  interactive || return 0
  _STEP_NO=$(( _STEP_NO + 1 ))
  local title="$*"
  printf '\n%s╔══════════════════════════════════════════════════════════════════╗%s\n' "$_C_STEP" "$_C_RST" >&2
  printf '%s║ STEP %-2d  %-56s ║%s\n' "$_C_STEP" "$_STEP_NO" "$title" "$_C_RST" >&2
  printf '%s╚══════════════════════════════════════════════════════════════════╝%s\n' "$_C_STEP" "$_C_RST" >&2
}

# explain <text...> — a short "what's happening / why it matters" note. Each
# argument is printed as its own wrapped line so callers can pass bullet points.
explain() {
  interactive || return 0
  local line
  for line in "$@"; do
    printf '%s  │ %s%s\n' "$_C_EXPLAIN" "$line" "$_C_RST" >&2
  done
}

# pause — wait for the presenter before moving on (or auto-advance under AUTO=1).
pause() {
  interactive || return 0
  if [[ "$AUTO" == "1" ]]; then
    printf '%s  … continuing in %ss%s\n' "$_C_DIM" "$STEP_DELAY" "$_C_RST" >&2
    sleep "$STEP_DELAY"
    return 0
  fi
  printf '\n%s  ▸ Press %sEnter%s%s to continue…%s ' "$_C_DIM" "$_C_KEY" "$_C_RST" "$_C_DIM" "$_C_RST" >&2
  read -r _ </dev/tty 2>/dev/null || read -r _ || true
}

# run_visible <cmd...> — show the exact command (so the audience sees the real
# porchctl/kubectl/flux calls) then execute it. Outside interactive mode it just
# runs the command quietly.
run_visible() {
  if interactive; then
    printf '%s  $ %s%s\n' "$_C_CMD" "$*" "$_C_RST" >&2
  fi
  "$@"
  local rc=$?
  # In interactive mode, wait for the presenter after each porchctl command (the
  # 'p' helper wraps porchctl) so each lifecycle step can be narrated. Other
  # commands (kubectl/flux) run without an extra pause.
  if interactive && [[ "$1" == "p" || "$1" == "porchctl" ]]; then
    pause
  fi
  return $rc
}

# show_pkgs [pkg-filter] — print the Porch package-revision table so the
# Draft → Proposed → Published lifecycle is visible. Optional awk filter on the
# package name column ($2).
show_pkgs() {
  interactive || return 0
  local filter="${1:-}"
  printf '%s  ── Porch package revisions %s──%s\n' "$_C_DIM" "${filter:+($filter) }" "$_C_RST" >&2
  if [[ -n "$filter" ]]; then
    porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
      | awk -v p="$filter" 'NR==1 || $2==p' | sed 's/^/    /' >&2 || true
  else
    porchctl rpkg get -n "$PORCH_NS" 2>/dev/null | sed 's/^/    /' >&2 || true
  fi
}

# show_diff <label> <before-dir> <after-dir> — show what customization Porch/KPT
# injected into a cloned package (the core value prop: clone a blueprint, then
# layer local edits that stay tracked + re-mergeable on upgrade).
show_diff() {
  interactive || return 0
  local label="$1" before="$2" after="$3"
  printf '%s  ── Diff: %s ──%s\n' "$_C_DIM" "$label" "$_C_RST" >&2
  if command -v diff >/dev/null 2>&1; then
    # Unified diff, colorized if the terminal supports it. '|| true' because diff
    # exits non-zero when there are differences (which is exactly what we want).
    diff -ruN "$before" "$after" 2>/dev/null \
      | sed -e "s/^+.*/${_C_EXPLAIN}&${_C_RST}/" -e "s/^-.*/${_C_KEY}&${_C_RST}/" -e 's/^/    /' >&2 || true
  else
    warn "  (diff not available — skipping visual diff)"
  fi
}

# show_kpt_render <pkg-dir> — the centerpiece of the demo: run KPT's function
# pipeline LOCALLY on a copy of the package so the audience watches KPT execute
# each function. Instead of rendering here (which would duplicate the render that
# Porch does on push), we hand the user a ready-to-run `kpt fn render` command on
# a saved COPY of the exact package about to be pushed — so they can watch KPT
# execute the pipeline and inspect the diff themselves, on demand. During the
# actual deploy only Porch renders (server-side, on push).
#
# No-op unless interactive.
show_kpt_render() {  # show_kpt_render <pkg-dir>
  interactive || return 0
  local src="$1"

  step "See KPT render the package (optional — run it yourself)"
  explain "KPT is the engine: it reads the Kptfile's function pipeline and runs" \
          "each function to transform the KRM. This package's pipeline:"
  # List the pipeline functions from the Kptfile so the audience sees what runs.
  if [[ -f "$src/Kptfile" ]]; then
    awk '
      /image:/     { fn=$0; sub(/.*\//,"",fn); sub(/:v[0-9].*/,"",fn); next }
      /configPath:/{ cfg=$2; sub(/.*\//,"",cfg); printf "      %-20s ← %s\n", fn, cfg }
    ' "$src/Kptfile" >&2 2>/dev/null || true
  fi

  # Save TWO identical copies of the customized (un-rendered) package: one to
  # render, and one to keep as the "before" baseline. Diffing them isolates
  # exactly what the KPT pipeline changed — same package, before vs after render.
  local snapdir; snapdir="$(mktemp -d)"
  local before="$snapdir/before-render" after="$snapdir/rendered"
  cp -r "$src" "$before"
  # Porch stamps a `status:` block into the Kptfile that older local `kpt`
  # rejects; strip it so the suggested command works out of the box.
  if [[ -f "$before/Kptfile" ]]; then
    awk '
      /^[^[:space:]].*:[[:space:]]*$/ || /^[^[:space:]].*:[[:space:]]/ {
        in_status = ($0 ~ /^status:[[:space:]]*$/)
      }
      { if (!in_status) print }
    ' "$before/Kptfile" > "$before/Kptfile.tmp" && mv "$before/Kptfile.tmp" "$before/Kptfile"
  fi
  cp -r "$before" "$after"

  explain "" \
          "Two identical copies of the customized (un-rendered) package are saved:" \
          "  before : $before" \
          "  after  : $after" \
          "" \
          "Render the 'after' copy, then diff the two — same package, before vs" \
          "after the pipeline runs. Run in another terminal:"
  printf '%s      # 1) KPT runs the function pipeline on the "after" copy:%s\n' "$_C_DIM" "$_C_RST" >&2
  printf '%s      kpt fn render %s%s\n' "$_C_CMD" "$after" "$_C_RST" >&2
  printf '%s      # 2) diff before vs after — exactly what KPT changed:%s\n' "$_C_DIM" "$_C_RST" >&2
  printf '%s      diff -ruN %s %s | head -100%s\n' "$_C_CMD" "$before" "$after" "$_C_RST" >&2
  command -v kpt >/dev/null 2>&1 || explain "(install kpt to run the above.)"
  explain "" \
          "During THIS deploy we don't render locally — we push the un-rendered" \
          "package and let PORCH run the exact same pipeline server-side, storing" \
          "the result as a versioned revision in git. KPT renders; Porch" \
          "orchestrates, versions, and publishes. That's the next step."
  pause
}

# Print an intro explaining the demo model once, at the very start of a run.
interactive_intro() {
  interactive || return 0
  cat >&2 <<EOF

${_C_STEP}┌────────────────────────────────────────────────────────────────────┐
│  otel-demo — KPT + Porch + Flux guided walkthrough              │
└────────────────────────────────────────────────────────────────────┘${_C_RST}
${_C_EXPLAIN}  This run is INTERACTIVE: it pauses between stages, explains what KPT
  and Porch are doing, and shows what changes (package lifecycle, KRM
  diffs, git-backed state, and Flux reconciliation).


  The model:
    • A pristine BLUEPRINT package (app-blueprint/) is published to Porch.
    • For each region we CLONE that blueprint, then layer small local edits
      (namespace, region, branding) — Porch tracks them as a new revision.
    • Publishing moves the revision Draft → Proposed → Published and commits
      the rendered KRM to git.
    • Flux watches git and reconciles the shop onto the region cluster.

  The point: no copy-pasted YAML. Blueprints are cloned, customized, and
  version-tracked, and can be re-merged on upgrade (see 'upgrade <region>').${_C_RST}
EOF
  pause
}

# ---------------------------------------------------------------------------
# 1. images — branded images are pre-published to a registry and pulled by the
#    workload clusters. Local build + kind-load is available but optional.
# ---------------------------------------------------------------------------
# The branded store images are published under:
#   ghcr.io/kptdev/kpt-samples/otel-demo/<name>:<tag>
# and are referenced directly by the app package (via the branding value-store
# ConfigMap). Region workload clusters pull them over the network, so a normal
# deploy needs no `docker build` / `kind load` step.
#
# For offline work or iterating on the image sources, build them locally with the
# `build` command or BUILD_LOCAL=1 (see build_images below).
#
# The registry namespace is overridable via IMAGE_REGISTRY for forks/mirrors.
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/kptdev/kpt-samples/otel-demo}"

# Branded images that this project publishes (informational — used by `images`
# for a quick reachability check and by teardown --images if pulled locally).
branded_images() {  # branded_images <astronomy|florist>
  local store="$1"
  case "$store" in
    astronomy) printf '%s\n' astronomy-frontend astronomy-ad astronomy-llm astronomy-email ;;
    florist)   printf '%s\n' florist-frontend florist-ad florist-llm florist-image-provider florist-load-generator email ;;
    *) die "unknown store '$store' (expected astronomy|florist)" ;;
  esac
}

# Optional convenience: verify the published images can be resolved from the
# registry (does not pull layers). Never required by a deploy.
check_images() {  # check_images <astronomy|florist>
  local store="${1:-astronomy}" name ref missing=0
  require docker
  log "Checking registry images for '$store' under $IMAGE_REGISTRY (tag :$IMAGE_TAG)"
  while read -r name; do
    ref="$IMAGE_REGISTRY/$name:$IMAGE_TAG"
    if docker manifest inspect "$ref" >/dev/null 2>&1; then
      log "  ok   $ref"
    else
      warn "  MISSING/unreachable $ref"; missing=$(( missing + 1 ))
    fi
  done < <(branded_images "$store")
  [[ "$missing" -eq 0 ]] && log "All '$store' images resolvable." \
                         || warn "$missing '$store' image(s) not resolvable (check registry access / login)."
}

# ---------------------------------------------------------------------------
# Optional: build the branded images locally and kind-load them, instead of
# pulling from the registry. This is NOT part of a normal deploy — it exists for
# offline/air-gapped work or when iterating on the image source. Two ways in:
#   * `deploy.sh build <astronomy|florist>`  (explicit, one-off)
#   * `BUILD_LOCAL=1 deploy.sh <region> ...` (build+load as part of a deploy)
#
# Images are tagged as "$IMAGE_REGISTRY/<name>:$IMAGE_TAG" — the exact reference
# the app package uses — and kind-loaded into every target cluster. With the
# manifests' `imagePullPolicy: IfNotPresent`, the loaded image is used and no
# registry pull happens.
build_images() {  # build_images <astronomy|florist> [target-cluster ...]
  local store="$1"; shift || true
  # One or more kind clusters to load into. Defaults to $MGMT_CLUSTER when none given.
  local target_clusters=("$@")
  [[ ${#target_clusters[@]} -eq 0 ]] && target_clusters=("$MGMT_CLUSTER")
  require docker; require kind
  local base="$REPO_ROOT/$store"
  [[ -d "$base" ]] || die "no source dir for store '$store' at $base"

  log "Building '$store' images locally (tag :$IMAGE_TAG) -> $IMAGE_REGISTRY"
  log "  target cluster(s): ${target_clusters[*]}"

  # name:dir:extra-build-args  (email builds to the shared 'email' image for florist)
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

  local name spec dir args ctx ref cl
  for name in "${!imgs[@]}"; do
    spec="${imgs[$name]}"
    dir="${spec%%|*}"
    args=""
    [[ "$spec" == *"|"* ]] && args="${spec#*|}"
    ctx="$base/$dir"
    [[ -d "$ctx" ]] || { warn "skip $name: no dir $ctx"; continue; }
    ref="$IMAGE_REGISTRY/$name:$IMAGE_TAG"
    log "  build $ref  (context: $store/$dir)"
    # shellcheck disable=SC2086
    docker build $args -t "$ref" "$ctx" >/dev/null
    # Load the freshly-built image into every target cluster.
    for cl in "${target_clusters[@]}"; do
      log "  kind load $ref -> $cl"
      kind load docker-image "$ref" --name "$cl" >/dev/null 2>&1 \
        || warn "  kind load failed for $ref -> $cl (does the cluster exist?)"
    done
  done
  log "'$store' images built and loaded into: ${target_clusters[*]}."
}

# ---------------------------------------------------------------------------
# porch helpers
# ---------------------------------------------------------------------------
p() { porchctl "$@" -n "$PORCH_NS"; }

latest_blueprint_rev() {  # latest_blueprint_rev [pkgname]
  local pkg="${1:-$BLUEPRINT_NAME}" out
  # Capture first, then filter — avoids SIGPIPE (exit 141) from head/awk closing
  # the pipe on the slow porchctl under `set -o pipefail`.
  out="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null || true)"
  printf '%s\n' "$out" | awk -v pkg="$pkg" '$2==pkg && $5=="true"{print $1}' | head -1
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
  if [[ "$GIT_BACKEND" == "gitlab" ]]; then
    explain "Lifecycle (GitLab): this Draft revision opens a Merge Request, marks it" \
            "ready (Proposed), then approves it (merges the MR) → Published." \
            "  $pr : Draft → (MR opened) → Proposed → Published"
    # GitLab repos use the Merge Request lifecycle: while still Draft, open the MR
    # for the draft branch (mergerequest), then propose (mark the MR ready), then
    # approve (merge it). approve is idempotent — if the MR was already merged in
    # GitLab directly, it reports "already approved". 'mr' aliases 'mergerequest';
    # both are valid only for type=gitlab.
    run_visible p rpkg mergerequest "$pr" >/dev/null
    sleep 2
    run_visible p rpkg propose "$pr" >/dev/null
    sleep 2
    run_visible p rpkg approve "$pr" >/dev/null
    show_pkgs
    return 0
  fi
  explain "Lifecycle: this Draft revision will be Proposed, then Approved →" \
          "Published. Publishing is what commits the server-rendered KRM to git." \
          "  $pr : Draft → Proposed → Published"
  run_visible p rpkg propose "$pr" >/dev/null
  sleep 2
  run_visible p rpkg approve "$pr" >/dev/null
  show_pkgs
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
            | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r && $5=="true"{print $1}' | head -1 || true)"
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
upgrade_pkg() {  # upgrade_pkg <repo> <pkg> <blueprint-name> [target-rev]
  local repo="$1" pkg="$2" bpname="$3" target_rev="${4:-}"
  # latest published downstream revision
  local latest; latest="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
      | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r && $5=="true"{print $1}' | head -1 || true)"
  [[ -n "$latest" ]] || { warn "no published $pkg in $repo to upgrade"; return 1; }
  # target upstream blueprint revision number. Default: the LATEST published
  # blueprint. If a target-rev was given, it must be an integer and a published
  # revision of this blueprint (passed straight to `rpkg upgrade --revision`).
  local bprev
  if [[ -n "$target_rev" ]]; then
    [[ "$target_rev" =~ ^[0-9]+$ ]] || { warn "revision must be an integer (got '$target_rev')"; return 1; }
    bprev="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
        | awk -v p="$bpname" -v w="$target_rev" '$2==p && $4==w{print $4}' | head -1 || true)"
    [[ -n "$bprev" ]] || { warn "revision $target_rev of $bpname not found (published?)"; return 1; }
  else
    bprev="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
        | awk -v p="$bpname" '$2==p && $5=="true"{print $4}' | head -1 || true)"
    [[ -n "$bprev" ]] || { warn "no published $bpname"; return 1; }
  fi
  # next downstream workspace
  local maxn ws newpr
  maxn="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
      | awk -v r="$repo" -v p="$pkg" '$2==p && $7==r{print $3}' | sed 's/^v//' | grep -E '^[0-9]+$' | sort -n | tail -1)"
  ws="v$(( maxn + 1 ))"
  newpr="${repo}.${pkg}.${ws}"
  log "  upgrade $latest -> $bpname rev $bprev (new $newpr)"
  p rpkg upgrade "$latest" --revision="$bprev" --workspace="$ws" >/dev/null 2>&1 || {
    warn "  rpkg upgrade failed (already at rev $bprev?)"; return 1; }
  wait_lifecycle "$newpr" Draft >/dev/null 2>&1 || true
  echo "$newpr"
}

# Upgrade a region's app + flux packages and republish.
# By default upgrades to the LATEST blueprints; an optional app-blueprint revision
# (integer) pins the app package to that specific blueprint revision. An optional
# store (astronomy|florist) re-brands the storefront during the upgrade; if
# omitted, the region keeps its current store (preserved by Porch's 3-way merge).
upgrade_region() {  # upgrade_region <region> [app-blueprint-rev] [store] [do-flux]
  local region; region="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  local target_rev="${2:-}"
  local store="${3:-}"
  local do_flux="${4:-0}"   # upgrade the flux wiring package too (default: no)
  local ns="${region}-otel-demo"
  local apps_repo="${region}${APPS_SUFFIX}" flux_repo="${region}${FLUX_SUFFIX}"
  require porchctl

  # Operate on the backend the region actually lives on (correct blueprints repo,
  # publish/MR flow, and git secret) even if --gitBackend wasn't passed.
  detect_region_backend "$region"
  resolve_blueprint_repo
  # Ensure a usable GitLab token for the publish/MR steps (no-op for gitea, and
  # idempotent if detect_region_backend already resolved one).
  [[ "$GIT_BACKEND" == "gitlab" ]] && ensure_gitlab_token

  # Validate store if provided.
  if [[ -n "$store" ]]; then
    store="$(echo "$store" | tr '[:upper:]' '[:lower:]')"
    case "$store" in
      astronomy|florist) ;;
      *) die "invalid --store '$store' — must be 'astronomy' or 'florist'" ;;
    esac
  fi

  if [[ -n "$target_rev" ]]; then
    log "Upgrade region $region to app blueprint revision $target_rev${store:+ (store=$store)}"
  else
    log "Upgrade region $region to latest blueprints${store:+ (store=$store)}"
  fi

  local apr; apr="$(upgrade_pkg "$apps_repo" "$PACKAGE_NAME" "$BLUEPRINT_NAME" "$target_rev" || true)"
  if [[ -n "$apr" ]]; then
    # If a store was requested, re-stamp storeType on the upgraded draft before publishing.
    if [[ -n "$store" ]]; then
      local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
      p rpkg pull "$apr" "$work" >/dev/null
      if [[ -f "$work/app-config.yaml" ]]; then
        log "  setting storeType=$store on $apr"
        # Handle both block style (`storeType: x` on its own line) and flow style
        # (`data: {... storeType: x ...}`).
        sed -i \
          -e "s|^\([[:space:]]*\)storeType:.*|\1storeType: $store|" \
          -e "s|\(storeType:[[:space:]]*\)[a-zA-Z-]*|\1$store|" \
          "$work/app-config.yaml"
        p rpkg push "$apr" "$work" >/dev/null
      else
        warn "  app-config.yaml not found in $apr; cannot set store"
      fi
      rm -rf "$tmp"
    fi
    publish "$apr" && log "  app upgraded + published: $apr"
  fi

  # Flux wiring upgrade is OPTIONAL — the flux-config rarely changes, so by default
  # an upgrade only rolls the app package. Pass --flux to also upgrade + republish
  # the region's flux wiring package (tracks its latest blueprint).
  if [[ "$do_flux" == "1" ]]; then
    local fpr; fpr="$(upgrade_pkg "$flux_repo" "$FLUX_PKG_NAME" "$FLUX_BLUEPRINT_NAME" || true)"
    if [[ -n "$fpr" ]]; then
      # rpkg upgrade's 3-way merge PRESERVES the existing flux-config values, so a
      # region originally wired with the wrong git secret (e.g. 'gitea' on a gitlab
      # backend) would stay wrong. Re-stamp gitSecret + gitBase on the upgraded
      # draft to match the CURRENT backend, so the inner GitRepository points at the
      # right secret. (Mirrors the storeType re-stamp above.)
      local ftmp; ftmp="$(mktemp -d)"; local fwork="$ftmp/pkg"
      p rpkg pull "$fpr" "$fwork" >/dev/null
      if [[ -f "$fwork/flux-config.yaml" ]]; then
        log "  setting gitSecret=$GIT_SECRET, gitBase=$GIT_BASE on $fpr"
        sed -i \
          -e "s|^\([[:space:]]*\)gitSecret:.*|\1gitSecret: $GIT_SECRET|" \
          -e "s|^\([[:space:]]*\)gitBase:.*|\1gitBase: $GIT_BASE|" \
          "$fwork/flux-config.yaml"
        # If the key is absent entirely (older flux-config), append it under data.
        grep -qE '^[[:space:]]*gitSecret:' "$fwork/flux-config.yaml" \
          || printf '  gitSecret: %s\n' "$GIT_SECRET" >> "$fwork/flux-config.yaml"
        p rpkg push "$fpr" "$fwork" >/dev/null
      else
        warn "  flux-config.yaml not found in $fpr; cannot set gitSecret"
      fi
      rm -rf "$ftmp"
      publish "$fpr" && log "  flux upgraded + published: $fpr"
    fi
  else
    log "  skipping flux wiring upgrade (pass --flux to include it)"
  fi

  # nudge Flux to pick up the new commits
  flux reconcile source git "${region}-flux" -n "$ns" --with-source >/dev/null 2>&1 || true
  flux reconcile kustomization "${region}-flux" -n "$ns" >/dev/null 2>&1 || true
  flux reconcile kustomization "$ns" -n "$ns" >/dev/null 2>&1 || true
  log "Upgrade complete for $region"
}

# ---------------------------------------------------------------------------
# 2. blueprint — push a local blueprint dir to the blueprints repo and publish
# ---------------------------------------------------------------------------
publish_blueprint() {  # publish_blueprint <name> <dir> [subpkgs-to-wipe...]
  local name="$1" dir="$2"; shift 2
  local wipe=("$@")
  require porchctl
  resolve_blueprint_repo
  [[ -f "$dir/Kptfile" ]] || die "no Kptfile at $dir"

  step "Publish blueprint '$name'"
  explain "A blueprint is a reusable KRM package (has a Kptfile) that regions will" \
          "CLONE. We push the local source to Porch, which renders it server-side" \
          "and stores it as a versioned, git-backed package revision." \
          "" \
          "Source dir : $dir" \
          "Blueprints repo (Porch/Gitea) : $BLUEPRINT_REPO"
  if interactive; then
    # Only show the existing revisions if there are any — on a first-time publish
    # the table is empty, which is just noise.
    if [[ -n "$(latest_blueprint_rev "$name" 2>/dev/null)" ]]; then
      explain "Existing revisions of this blueprint (a new one will be added):"
      show_pkgs "$name"
    else
      explain "No revisions of '$name' exist yet — this publish creates v1."
    fi
    pause
  fi

  # Ensure prerequisites for the blueprints repo. If it already exists (reuse
  # case — possibly on a different backend than the current --gitBackend), leave
  # it exactly as-is: don't recreate the git repo, don't touch its secret, and
  # don't re-register it (which would fail the backend check). Blueprints are a
  # backend-agnostic package source cloned via Porch. Only create + register when
  # the resolved repo doesn't exist yet.
  if kubectl get repository "$BLUEPRINT_REPO" -n "$PORCH_NS" >/dev/null 2>&1; then
    log "Reusing existing blueprints repo '$BLUEPRINT_REPO' (backend-agnostic; left as-is)"
  else
    ensure_git_secret
    ensure_git_repo "$BLUEPRINT_REPO"
    ensure_repo_registered "$BLUEPRINT_REPO" "$BLUEPRINT_REPO" "/" false
  fi

  # No local `kpt fn render` (Porch renders server-side on push; a local render
  # would mutate the pristine source dir in place).
  local existing ws draft
  existing="$(latest_blueprint_rev "$name" || true)"
  if [[ -z "$existing" ]]; then
    ws="v1"
    log "Creating new blueprint $name/$ws in $BLUEPRINT_REPO"
    explain "No revision exists yet → 'rpkg init' creates the first Draft (v1)."
    run_visible p rpkg init "$name" --repository="$BLUEPRINT_REPO" --workspace="$ws" \
        --description="$name" >/dev/null
    draft="${BLUEPRINT_REPO}.${name}.${ws}"
  else
    local maxn
    maxn="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
            | awk -v pkg="$name" '$2==pkg{print $4}' | grep -E '^[0-9]+$' | sort -n | tail -1)"
    ws="v$(( maxn + 1 ))"
    log "Copying $existing -> new workspace $ws"
    explain "A published revision already exists → 'rpkg copy' opens a new editable" \
            "Draft ($ws). You never edit a Published revision in place."
    run_visible p rpkg copy "$existing" --workspace="$ws" >/dev/null
    draft="${BLUEPRINT_REPO}.${name}.${ws}"
  fi
  wait_lifecycle "$draft" Draft || warn "draft $draft not ready yet"

  local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
  log "Pulling draft metadata to $work"
  explain "'rpkg pull' materializes the Draft locally so we can lay our source" \
          "content on top of Porch's package metadata (Kptfile, etc.)."
  run_visible p rpkg pull "$draft" "$work" >/dev/null
  local d; for d in "${wipe[@]}"; do rm -rf "$work/$d"; done
  cp -r "$dir/." "$work/"
  log "Pushing package content to $draft (server-side render)"
  explain "'rpkg push' uploads the content. Porch runs the Kptfile's function" \
          "pipeline SERVER-SIDE (no local 'kpt fn render'), so the pristine source" \
          "dir is never mutated — a key KPT/Porch guarantee."
  run_visible p rpkg push "$draft" "$work" >/dev/null
  if interactive; then pause; fi
  publish "$draft"
  rm -rf "$tmp"
  log "Blueprint published: $draft"
  explain "Blueprint '$name' is now Published and committed to git. Regions can" \
          "clone it by name — that's the next stage."
  if interactive; then pause; fi
}

# Publish the app blueprint (with its subpackages) — the 'blueprint' command.
push_blueprint() {
  publish_blueprint "$BLUEPRINT_NAME" "$BLUEPRINT_DIR" shop observability
}

# Publish the flux blueprint (no subpackages).
push_flux_blueprint() {
  publish_blueprint "$FLUX_BLUEPRINT_NAME" "$FLUX_BLUEPRINT_DIR"
}

# Publish the NEXT, FIXED version of the app blueprint by EVOLVING the latest
# published revision inside Porch (no second source dir on disk): copy the latest
# revision to a new workspace, edit the draft to remove chaos (so the app runs
# clean) + bump memory, then publish. The new revision number is chosen
# automatically (max existing + 1), so this can be run repeatedly to produce the
# next fixed revision each time, carrying the same set of improvements.
#
# The fixes applied to the draft:
#   * app-config.yaml         — drop the `chaos` input key (no longer configurable)
#   * app-config-schema.yaml  — drop `chaos` from required + properties
#   * setup-extras.yaml       — hardcode the chaos scenario to "off" (flags always
#                               off) instead of reading it from app-config
#   * flagd + checkout        — bump memory +10Mi (accumulating per version) so the
#                               pod spec changes and they RESTART on upgrade
#
# This demonstrates blueprint evolution: a published package is copied to a new
# revision, changed (chaos removed → a working blueprint), and re-published —
# downstream clones can then be upgraded.
push_blueprint_fixed() {
  require porchctl
  resolve_blueprint_repo
  local name="$BLUEPRINT_NAME"

  # A base revision must exist first (publish v1 from source if needed).
  if [[ -z "$(latest_blueprint_rev "$name" 2>/dev/null)" ]]; then
    log "No published blueprint yet; publishing the base (v1) from source first"
    push_blueprint
  fi
  local latest; latest="$(latest_blueprint_rev "$name")"
  [[ -n "$latest" ]] || die "failed to resolve published $name base revision"

  # New numeric workspace = max(existing) + 1 (v2, v3, …).
  local maxn ws draft
  maxn="$(porchctl rpkg get -n "$PORCH_NS" 2>/dev/null \
          | awk -v pkg="$name" '$2==pkg{print $4}' | grep -E '^[0-9]+$' | sort -n | tail -1)"
  ws="v$(( maxn + 1 ))"

  step "Publish blueprint '$name' $ws (evolve latest: remove chaos + bump flagd/checkout)"
  explain "$ws is created by COPYING the latest published revision ($latest) to a" \
          "new revision and editing it in Porch — no second source dir. Changes:" \
          "remove the 'chaos' input entirely (app-config, schema, pipeline) so it" \
          "always runs off, and bump flagd/checkout memory +10Mi so they restart" \
          "on upgrade."
  if interactive; then show_pkgs "$name"; pause; fi

  log "Copying $latest -> new workspace $ws"
  explain "'rpkg copy' opens an editable Draft ($ws) from the latest published revision."
  run_visible p rpkg copy "$latest" --workspace="$ws" >/dev/null
  draft="${BLUEPRINT_REPO}.${name}.${ws}"
  wait_lifecycle "$draft" Draft || warn "draft $draft not ready yet"

  local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
  run_visible p rpkg pull "$draft" "$work" >/dev/null
  local work_orig=""
  if interactive; then work_orig="$tmp/pkg.orig"; cp -r "$work" "$work_orig"; fi

  # --- v2 edit 1: drop the chaos key from app-config.yaml ---
  if [[ -f "$work/app-config.yaml" ]]; then
    log "Removing 'chaos' key from app-config.yaml"
    # YAML-aware removal: delete data.chaos regardless of block or flow style,
    # and strip the chaos doc-comment lines. (A line-based sed misses the key
    # when `data` is written inline as `{... chaos: x}`.)
    python3 - "$work/app-config.yaml" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p).read().split("\n")
out = []
for ln in lines:
    stripped = ln.strip()
    # drop chaos doc-comment lines
    if stripped.startswith("#") and ("chaos" in stripped or "broken-catalog | memory-leak" in stripped):
        continue
    # drop a block-style `chaos:` data key on its own line
    if re.match(r'^\s*chaos:\s', ln) or re.match(r'^\s*chaos:\s*$', ln):
        continue
    # drop chaos from an inline/flow-style data map: {a: 1, chaos: x, b: 2}
    if "{" in ln and "chaos:" in ln:
        ln = re.sub(r',?\s*chaos:\s*[^,}]+', '', ln)
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
  fi

  # --- v2 edit 2: drop chaos from the schema (required + properties) ---
  if [[ -f "$work/app-config-schema.yaml" ]]; then
    log "Removing 'chaos' from app-config-schema.yaml"
    # remove the "- chaos" required entry
    sed -i '/^[[:space:]]*-[[:space:]]*chaos[[:space:]]*$/d' "$work/app-config-schema.yaml"
    # remove the chaos property block (the 'chaos:' key and its two indented lines:
    # 'type: string' and the 'enum: [...]' line)
    sed -i '/^[[:space:]]*chaos:[[:space:]]*$/,+2d' "$work/app-config-schema.yaml"
  fi

  # --- v2 edit 3: hardcode chaos scenario to "off" in setup-extras.yaml ---
  # Replace the block that reads chaos from app-config with a fixed scenario.
  if [[ -f "$work/setup-extras.yaml" ]]; then
    log "Hardcoding chaos scenario to 'off' in setup-extras.yaml"
    python3 - "$work/setup-extras.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Replace the whole config-reading region — from the initial `scenario = "off"`
# default line through the trailing fail() — with a single hardcoded assignment,
# so v2 has exactly one `scenario = "off"` (no redundant duplicate).
#     scenario = "off"
#
#     # Read chaos scenario from config
#     for r in resources:
#       if krmfn.match_gvk(... "app-config"):
#         scenario = r.get("data", {}).get("chaos", "off")
#
#     if scenario == None:
#       scenario = "off"
#     if scenario == "":
#       fail("chaos cannot be empty in app-config")
pat = re.compile(
    r'[ \t]*scenario = "off"\n'
    r'(?:.*\n)*?'
    r'[ \t]*fail\("chaos cannot be empty in app-config"\)\n'
)
repl = '    # v2: chaos removed as a configurable input; always run with it off.\n    scenario = "off"\n'
s2, n = pat.subn(repl, s, count=1)
if n == 0:
    sys.stderr.write("WARN: chaos read block not found in setup-extras.yaml; left unchanged\n")
open(p, "w").write(s2)
PY
  fi

  # --- vX edit 4: bump flagd + checkout memory by +10Mi each version. Because
  # setup_profile resets memory from UPSTREAM_MEMORY_LIMITS on every render, the
  # bump is applied THERE (not on the raw deployment, which would be overwritten).
  # Each version adds +10Mi, so the value strictly increases (v2=310/110,
  # v3=320/120, …). The changing pod spec forces flagd + checkout to RESTART on
  # every 'upgrade', which clears flagd's stale in-memory config and checkout's
  # stuck gRPC name resolver.
  if [[ -f "$work/setup-extras.yaml" ]]; then
    log "Bumping flagd + checkout memory by 10Mi (forces restart on upgrade)"
    python3 - "$work/setup-extras.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
def bump(text, svc, delta=10):
    # match e.g.  "flagd": "300Mi",  and add delta to the number
    pat = re.compile(r'("' + re.escape(svc) + r'":\s*")(\d+)(Mi")')
    def repl(m):
        return m.group(1) + str(int(m.group(2)) + delta) + m.group(3)
    new, n = pat.subn(repl, text, count=1)
    if n == 0:
        sys.stderr.write("WARN: UPSTREAM_MEMORY_LIMITS entry for %s not found\n" % svc)
    return new
s = bump(s, "flagd")
s = bump(s, "checkout")
open(p, "w").write(s)
PY
  fi

  if interactive && [[ -n "$work_orig" ]]; then
    show_diff "$ws changes (chaos removed + flagd/checkout +10Mi) vs previous" "$work_orig" "$work"
    explain "$ws delta: chaos removed from the input/schema/pipeline, and" \
            "flagd/checkout memory bumped +10Mi so they RESTART on upgrade (clears" \
            "flagd's stale config + checkout's stuck gRPC resolver)." \
            "Branding/region/profile unchanged."
    pause
  fi

  log "Pushing $ws content to $draft (server-side render)"
  run_visible p rpkg push "$draft" "$work" >/dev/null
  if interactive; then pause; fi
  publish "$draft"
  rm -rf "$tmp"
  log "Blueprint $ws published: $draft"
  explain "$ws is Published. Roll a region forward with '$0 upgrade <region>' —" \
          "Porch 3-way-merges $ws into the region's clone, dropping chaos while" \
          "preserving that region's namespace/region/store customizations."
}

# ---------------------------------------------------------------------------
# 3. deploy — clone blueprint into a region repo, set region + namespace (+ store),
#    publish, and register it in the Flux config package (GitOps).
# ---------------------------------------------------------------------------
deploy_target() {  # deploy_target <region> [store]
  local region_in="$1" store="${2:-astronomy}"
  local region; region="$(echo "$region_in" | tr '[:upper:]' '[:lower:]')"   # ireland
  store="$(echo "$store" | tr '[:upper:]' '[:lower:]')"

  # --- validate inputs before doing any work ---
  case "$store" in
    astronomy|florist) ;;
    *) die "invalid store '$store' — must be 'astronomy' or 'florist'. Usage: $0 <region> [astronomy|florist]" ;;
  esac
  local valid_regions="us india czech-republic china ireland sweden hungary"
  if ! printf '%s\n' $valid_regions | grep -qx "$region"; then
    die "invalid region '$region' — must be one of: ${valid_regions// /, }"
  fi

  local ns="${region}-otel-demo"                                             # ireland-otel-demo
  local apps_repo="${region}${APPS_SUFFIX}"                                  # ireland-apps
  local pkg="${PACKAGE_NAME}"                                                # otel-demo
  local region_cl; region_cl="$(region_cluster "$region")"                   # kind cluster name
  local kubeconfig_secret="${region}-kubeconfig"
  require porchctl; require kubectl
  # All Porch/Flux control-plane ops run against the management cluster.
  kubectl config use-context "$MGMT_CONTEXT" >/dev/null 2>&1 || true

  # Adopt the region's existing backend when --gitBackend wasn't explicitly given,
  # so a re-deploy/upgrade of a gitlab region uses the right backend automatically.
  # (If --gitBackend WAS given and mismatches, detection defers and the guard below
  # fails fast with teardown guidance.)
  detect_region_backend "$region"

  # --- Backend consistency: fail fast if THIS REGION's repos were already deployed
  # on a DIFFERENT git backend. Checked here, before any cluster/secret/repo side
  # effects, so a mismatched '--gitBackend' aborts cleanly and tells the user to
  # tear the region down first. The shared 'blueprints' repo is intentionally NOT
  # checked: blueprints are a backend-agnostic package source and may live on any
  # backend regardless of where a region is deployed. ---
  assert_repo_backend "$apps_repo" "$region"
  assert_repo_backend "${region}${FLUX_SUFFIX}" "$region"

  # Resolve which blueprints repo to use (reuse existing on any backend, else a
  # backend-appropriate name). Backend-agnostic — not tied to this region's backend.
  resolve_blueprint_repo

  step "Deploy region '$region' (store: $store)"
  explain "Target namespace : $ns" \
          "Apps Porch repo  : $apps_repo  (Gitea $region.git → /apps)" \
          "Workload cluster : $region_cl  (a separate kind cluster)" \
          "" \
          "Model: this management cluster runs Porch + Flux; the shop runs on the" \
          "region cluster. Flux applies it REMOTELY via a kubeconfig Secret."
  if interactive; then pause; fi

  # --- Region workload cluster: create it (images are pulled from the registry) ---
  ensure_region_cluster "$region"
  # `kind create cluster` switches the active kubectl context to the new (region)
  # cluster. Switch back to the management cluster so the Porch/secret/blueprint
  # operations below don't accidentally run against the region cluster.
  kubectl config use-context "$MGMT_CONTEXT" >/dev/null 2>&1 || true
  # Optional: build the branded images locally and side-load them into this region
  # cluster instead of pulling from the registry (offline / iterating on sources).
  if [[ "${BUILD_LOCAL:-0}" == "1" ]]; then
    log "BUILD_LOCAL=1: building + kind-loading '$store' images into region cluster $region_cl"
    build_images "$store" "$region_cl"
  fi
  # store the region cluster's kubeconfig as a Secret on the mgmt cluster (for Flux remote-apply)
  ensure_region_kubeconfig_secret "$region" "$ns"

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
  # Ensure Flux controllers + git secret exist on the mgmt cluster (idempotent).
  kubectl get deploy kustomize-controller -n "$FLUX_NS" >/dev/null 2>&1 || flux_init

  log "Deploy: region=$region store=$store ns=$ns  cluster=$region_cl  apps-repo=$apps_repo  (from $src)"

  # Auto-create the backing git repo + register the two Porch repos (both on <region>.git).
  ensure_git_repo "$region"
  ensure_repo_registered "$apps_repo" "$region" "/apps"
  ensure_repo_registered "${region}${FLUX_SUFFIX}" "$region" "/flux-config"

  # Resolve an editable Draft revision: clone if absent, else copy latest to a new
  # workspace (can't push to a Published revision).
  step "Clone the blueprint for region '$region'"
  explain "Instead of copy-pasting YAML, Porch CLONES the published blueprint into" \
          "the region's repo ($apps_repo → /apps). The clone records its upstream," \
          "so later 'upgrade $region' can 3-way-merge new blueprint versions in." \
          "" \
          "Upstream blueprint : $src"
  local pr; pr="$(editable_draft "$apps_repo" "$pkg" "clone" "$src")"
  explain "Editable Draft revision: $pr"
  if interactive; then show_pkgs "$pkg"; pause; fi

  # pull, set namespace + region + branding, push
  local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
  run_visible p rpkg pull "$pr" "$work" >/dev/null
  # Snapshot the pristine clone so we can show exactly what our customization
  # changes (the core Porch story: clone once, layer local edits on top).
  local work_orig=""
  if interactive; then
    work_orig="$tmp/pkg.orig"
    cp -r "$work" "$work_orig"
  fi

  step "Customize the cloned package (namespace / region / branding)"
  explain "We now layer region-specific edits onto the clone — all in ONE file," \
          "app-config.yaml. These are small declarative KRM edits; Porch re-renders" \
          "the whole package server-side on push, so downstream resources stay" \
          "consistent."
  local appcfg="$work/app-config.yaml"
  if [[ ! -f "$appcfg" ]]; then
    die "app-config.yaml not found in the cloned package at $appcfg (is the blueprint up to date?)"
  fi
  log "Setting namespace=$ns, region=$region, storeType=$store in app-config.yaml"
  # Edit the three per-deployment keys in place, leaving profile/chaos at whatever
  # the clone ships. Anchor on the leading indentation so we only touch data keys.
  sed -i \
    -e "s|^\([[:space:]]*\)namespace:.*|\1namespace: $ns|" \
    -e "s|^\([[:space:]]*\)region:.*|\1region: $region|" \
    -e "s|^\([[:space:]]*\)storeType:.*|\1storeType: $store|" \
    "$appcfg"
  # Show precisely what we changed vs the pristine clone.
  if interactive && [[ -n "$work_orig" ]]; then
    show_diff "region customizations injected into the cloned package" "$work_orig" "$work"
    explain "That's the entire per-region delta — three tiny config inputs. The" \
            "Kptfile function pipeline expands them into the full rendered KRM on" \
            "push (namespaces, ConfigMaps, region locale, branded images, …)."
    pause
  fi
  # Watch KPT run the function pipeline locally and show what it mutates, then
  # explain that Porch performs this same render server-side on push.
  show_kpt_render "$work"
  log "Pushing customized app package (server-side render)"
  explain "On push, Porch runs the function pipeline server-side and records a new" \
          "revision. Watch the lifecycle move to Published next."
  run_visible p rpkg push "$pr" "$work" >/dev/null
  if interactive; then pause; fi
  publish "$pr"
  rm -rf "$tmp"
  log "Published app package: $pr (in $apps_repo -> /apps)"

  # GitOps: publish the region's Flux wiring package into <region>-flux-config.
  add_flux_config "$region" "$ns" "$kubeconfig_secret"
  # Seed the per-region Flux root that watches <region>.git /flux-config.
  flux_bootstrap_region "$region"

  deploy_summary "$region" "$ns" "$store"
}

# Print a clean "deployment complete" summary with access instructions.
deploy_summary() {  # deploy_summary <region> <ns> <store>
  local region="$1" ns="$2" store="$3"
  local region_cl; region_cl="$(region_cluster "$region")"
  local rctx="kind-${region_cl}"
  cat >&2 <<EOF

$(printf '\033[1;32m')============================================================$(printf '\033[0m')
$(printf '\033[1;32m')  Deployment complete: $region ($store)$(printf '\033[0m')
$(printf '\033[1;32m')  workload cluster: $region_cl   namespace: $ns$(printf '\033[0m')
$(printf '\033[1;32m')============================================================$(printf '\033[0m')

Flux (on the management cluster) is reconciling the app onto the '$region_cl'
cluster. Check the Flux status on management, and the workloads on the region:

  kubectl --context $MGMT_CONTEXT get kustomization -n $ns
  kubectl --context $rctx get pods -n $ns

Access the store (port-forward blocks; run in its own terminal):

  kubectl --context $rctx port-forward -n $ns svc/frontend-proxy 8080:8080

Then open:
  Storefront   http://localhost:8080/
  Grafana      http://localhost:8080/grafana/     (503 until Grafana is Ready)
  Jaeger       http://localhost:8080/jaeger/ui/
  Feature UI   http://localhost:8080/feature/
  Load gen     http://localhost:8080/loadgen/

Tear down with:  $0 teardown $region
EOF
}

# --- Multi-cluster helpers -------------------------------------------------
region_cluster() { echo "${REGION_CLUSTER_PREFIX}$1"; }   # kind cluster name for a region

# Warn (and optionally raise) inotify limits — the common cause of kind create
# failing with 'could not find a log line ... Multi-User System' on multi-cluster hosts.
check_inotify() {
  local inst; inst="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
  if [[ "$inst" -lt 1024 ]]; then
    warn "fs.inotify.max_user_instances=$inst is low for running multiple kind clusters."
    warn "If 'kind create' fails, raise it:  sudo sysctl fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576"
  fi
}

# Ensure the region's kind cluster exists.
ensure_region_cluster() {  # ensure_region_cluster <region>
  require kind
  local region="$1" cl; cl="$(region_cluster "$region")"
  if kind get clusters 2>/dev/null | grep -qx "$cl"; then
    log "Region cluster '$cl' already exists"
    return 0
  fi
  check_inotify
  log "Creating region kind cluster '$cl'"
  # surface kind's error (to stderr) rather than swallowing it
  if ! kind create cluster --name "$cl" >&2; then
    kind delete cluster --name "$cl" >/dev/null 2>&1 || true   # clean up a partial cluster
    die "kind create cluster '$cl' failed (see above). Common fix: raise inotify limits — sudo sysctl fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576"
  fi
}

# Container IP of the region cluster's control-plane on the docker 'kind' network.
region_cluster_ip() {  # region_cluster_ip <region>
  local cl; cl="$(region_cluster "$1")"
  docker inspect "${cl}-control-plane" \
    --format '{{range .NetworkSettings.Networks}}{{if eq .NetworkID (index $.NetworkSettings.Networks "kind").NetworkID}}{{end}}{{.IPAddress}}{{end}}' 2>/dev/null \
    | head -1
}

# Create/refresh the kubeconfig Secret for the region cluster in <ns> on the mgmt
# cluster. Uses the internal kubeconfig rewritten to the control-plane IP (which is
# a cert SAN, so TLS verifies) so mgmt-cluster Flux pods can reach it.
ensure_region_kubeconfig_secret() {  # ensure_region_kubeconfig_secret <region> <ns>
  require kind; require docker
  local region="$1" ns="$2" cl ip secret kc
  cl="$(region_cluster "$region")"
  secret="${region}-kubeconfig"
  ip="$(docker inspect "${cl}-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)"
  [[ -n "$ip" ]] || die "could not determine control-plane IP for cluster $cl"
  kc="$(mktemp)"
  kind get kubeconfig --internal --name "$cl" 2>/dev/null \
    | sed "s#server: https://${cl}-control-plane:6443#server: https://${ip}:6443#" > "$kc"
  log "Storing kubeconfig secret '$secret' in $ns (region cluster $cl @ $ip)"
  kubectl --context "$MGMT_CONTEXT" create namespace "$ns" >/dev/null 2>&1 || true
  kubectl --context "$MGMT_CONTEXT" create secret generic "$secret" -n "$ns" \
    --from-file=value="$kc" --dry-run=client -o yaml \
    | kubectl --context "$MGMT_CONTEXT" apply -f - >/dev/null
  rm -f "$kc"
}

# Ensure the Porch namespace exists (on the management cluster).
ensure_porch_ns() {
  require kubectl
  kubectl --context "$MGMT_CONTEXT" get ns "$PORCH_NS" >/dev/null 2>&1 || {
    log "Creating namespace $PORCH_NS"; kubectl --context "$MGMT_CONTEXT" create namespace "$PORCH_NS" >/dev/null; }
}

# Ensure the git auth Secret in the Porch namespace matches the SELECTED backend
# (source of truth that gets replicated into flux-system and each region namespace).
# Following loadTest/suite.sh: the secret is ALWAYS reconciled to the current
# backend's credentials (via apply), so a stale/broken secret from a previous run
# or a different provider can never linger. GitLab requires a real PAT — we fail
# fast if none was provided rather than writing a broken secret.
ensure_git_secret() {
  require kubectl
  ensure_porch_ns
  # GitLab requires a real Personal Access Token — an account password is rejected
  # over HTTP Basic. First try to obtain one automatically (cache/provision), then
  # fail fast (with guidance) only if that still yields nothing.
  if [[ "$GIT_BACKEND" == "gitlab" ]]; then
    ensure_gitlab_token
    if [[ -z "$GIT_PASS" ]]; then
      die "GitLab backend needs a Personal Access Token, but none was provided or auto-provisioned."$'\n'\
"       Either start the '$GITLAB_CONTAINER' container (for auto-provisioning), or"$'\n'\
"       create a PAT in GitLab (User Settings → Access Tokens) with scopes:"$'\n'\
"           api, read_repository, write_repository"$'\n'\
"       Then re-run with it, e.g.:"$'\n'\
"           GITLAB_TOKEN=<your-token> $0 <region> --gitBackend gitlab"$'\n'\
"       (GITLAB_USER defaults to '$GITLAB_USER'; override if your GitLab user differs.)"
    fi
    # A raw account password (as opposed to a PAT) is the most common mistake —
    # warn if it looks like the old placeholder, but don't block a real short token.
    [[ "$GIT_PASS" == "secret" ]] && warn "GITLAB token looks like the placeholder 'secret' — GitLab will reject a password; use a real PAT."
  fi
  # Always reconcile (create-or-update) so the stored credential matches the
  # selected backend/token. 'apply' is idempotent and refreshes an existing secret.
  log "Reconciling git auth secret '$GIT_SECRET' in $PORCH_NS (backend=$GIT_BACKEND user=$GIT_USER)"
  kubectl --context "$MGMT_CONTEXT" create secret generic "$GIT_SECRET" -n "$PORCH_NS" \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$GIT_USER" \
    --from-literal=password="$GIT_PASS" \
    --dry-run=client -o yaml | kubectl --context "$MGMT_CONTEXT" apply -f - >/dev/null
}

# Create the backing git repo (auto-init with main branch) if it doesn't exist.
# Dispatches to the selected backend's API. Idempotent.
ensure_git_repo() {  # ensure_git_repo <repo>
  case "$GIT_BACKEND" in
    gitea)  ensure_gitea_repo "$1" ;;
    gitlab) ensure_gitlab_repo "$1"; ensure_gitlab_webhook "$1" ;;
    *)      die "invalid GIT_BACKEND '$GIT_BACKEND'" ;;
  esac
}

# Create the backing Gitea repo (auto-init with main branch) if it doesn't exist.
ensure_gitea_repo() {  # ensure_gitea_repo <repo>
  local repo="$1"
  if curl -s -o /dev/null -w '%{http_code}' -u "$GIT_USER:$GIT_PASS" \
       "$GIT_API/repos/$GIT_USER/$repo" 2>/dev/null | grep -q '^200$'; then
    return 0
  fi
  log "Creating Gitea repo $GIT_USER/$repo"
  curl -s -o /dev/null -u "$GIT_USER:$GIT_PASS" -X POST "$GIT_API/user/repos" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$repo\",\"private\":false,\"auto_init\":true,\"default_branch\":\"main\"}" 2>/dev/null || true
}

# Create the backing GitLab project (auto-init with a README so 'main' exists) if
# it doesn't exist. Uses the GitLab REST API v4 with a Private-Token header
# (GIT_PASS is the personal access token). The project is created under the
# authenticated user's namespace with path == $repo, which yields the git URL
# $GITLAB_BASE/$repo.git that ensure_repo_registered points Porch at.
ensure_gitlab_repo() {  # ensure_gitlab_repo <repo>
  local repo="$1"
  # URL-encode "<user>/<repo>" for the project lookup path.
  local proj_path="$GIT_USER%2F$repo"
  if curl -ks -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $GIT_PASS" \
       "$GIT_API/projects/$proj_path" 2>/dev/null | grep -q '^200$'; then
    return 0
  fi
  log "Creating GitLab project $GIT_USER/$repo"
  # initialize_with_readme=true creates the default branch (main) so Porch/Flux
  # have something to clone; default_branch pins it to main. Status handling
  # mirrors loadTest/suite.sh: 201=created, 400|409=already exists (GitLab returns
  # 400 "has already been taken"), anything else is a real error.
  local resp http_code
  resp=$(curl -ks -X POST "$GIT_API/projects" \
    -H "PRIVATE-TOKEN: $GIT_PASS" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$repo\",\"path\":\"$repo\",\"visibility\":\"public\",\"initialize_with_readme\":true,\"default_branch\":\"main\"}" \
    -w '\nHTTP_CODE:%{http_code}' 2>&1) || true
  http_code=$(echo "$resp" | grep 'HTTP_CODE:' | cut -d: -f2)
  case "$http_code" in
    201)     log "  GitLab project created: $GIT_USER/$repo" ;;
    400|409) log "  GitLab project already exists: $GIT_USER/$repo" ;;
    401|403) die "GitLab API rejected the token creating '$repo' (HTTP $http_code). Check GITLAB_TOKEN scopes (api, read_repository, write_repository) and GITLAB_USER='$GITLAB_USER'." ;;
    *)       warn "  unexpected GitLab API response creating '$repo' (HTTP ${http_code:-none}) — continuing; repo may already exist" ;;
  esac
}

# Ensure the Porch webhook token secret exists (creating it with a random value if
# missing) and that porch-server is running with it. porch-server reads the token
# via the PORCH_SCM_WEBHOOK_TOKEN env (secretKeyRef, optional) ONLY at startup, so
# when we create the secret we also restart porch-server to pick it up. Idempotent:
# if the secret already exists it's left as-is and no restart happens.
ensure_webhook_secret() {
  require kubectl
  if kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" get secret "$WEBHOOK_SECRET" >/dev/null 2>&1; then
    return 0
  fi
  local token
  token="$(openssl rand -hex 32 2>/dev/null || true)"
  [[ -n "$token" ]] || token="$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  log "Creating Porch webhook token secret '$WEBHOOK_SECRET' in $WEBHOOK_NS"
  kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" create secret generic "$WEBHOOK_SECRET" \
    --from-literal=token="$token" >/dev/null
  # porch-server reads PORCH_SCM_WEBHOOK_TOKEN at startup only → restart to apply.
  if kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" get deploy "$WEBHOOK_SERVER_DEPLOY" >/dev/null 2>&1; then
    log "  restarting $WEBHOOK_SERVER_DEPLOY to pick up PORCH_SCM_WEBHOOK_TOKEN"
    kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" rollout restart deploy "$WEBHOOK_SERVER_DEPLOY" >/dev/null 2>&1 || true
    kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" rollout status deploy "$WEBHOOK_SERVER_DEPLOY" --timeout=120s >/dev/null 2>&1 \
      || warn "  $WEBHOOK_SERVER_DEPLOY rollout not confirmed within timeout (webhook auth may lag until it restarts)"
  else
    warn "  deployment $WEBHOOK_NS/$WEBHOOK_SERVER_DEPLOY not found; restart it manually so it reads the new token"
  fi
}

# Register (idempotently) the Porch SCM webhook on a GitLab project so merged MRs
# notify Porch's receiver. Ported from loadTest/gitlab/add-webhooks.sh. Resolves
# the target live from the cluster; best-effort — warns and returns on any missing
# piece rather than failing the deploy. No-op unless the gitlab backend is selected
# and WEBHOOK_REGISTER=1.
ensure_gitlab_webhook() {  # ensure_gitlab_webhook <repo>
  [[ "$GIT_BACKEND" == "gitlab" ]] || return 0
  [[ "$WEBHOOK_REGISTER" == "1" ]] || return 0
  local repo="$1"
  require kubectl

  # Make sure Porch's shared webhook token exists (auto-created if missing) so the
  # GitLab hook and porch-server agree on the X-Gitlab-Token.
  ensure_webhook_secret

  # Resolve the webhook token GitLab must send as X-Gitlab-Token (from the secret,
  # unless overridden). Empty is allowed: Porch skips verification when unset.
  local token="$WEBHOOK_TOKEN"
  if [[ -z "$token" ]]; then
    token="$(kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" get secret "$WEBHOOK_SECRET" \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  [[ -z "$token" ]] && warn "  webhook token empty (secret $WEBHOOK_NS/$WEBHOOK_SECRET not found) — Porch must also have an empty token for deliveries to be accepted"

  # Resolve the webhook target IP + port from the LoadBalancer service (live), so
  # we stay correct regardless of the configured port (e.g. 9090 vs 9494).
  local ip="$WEBHOOK_IP" port="$WEBHOOK_PORT"
  [[ -z "$ip" ]] && ip="$(kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" get svc "$WEBHOOK_LB_SVC" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -z "$port" ]] && port="$(kubectl --context "$MGMT_CONTEXT" -n "$WEBHOOK_NS" get svc "$WEBHOOK_LB_SVC" \
      -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  if [[ -z "$ip" || -z "$port" ]]; then
    warn "  could not resolve Porch webhook endpoint (svc $WEBHOOK_NS/$WEBHOOK_LB_SVC has no LB IP/port); skipping webhook registration for '$repo'"
    return 0
  fi
  local webhook_url="http://${ip}:${port}${WEBHOOK_PATH}"

  # The GitLab project must exist (it's created just before this call).
  local proj="${GIT_USER}%2F${repo}"
  local code
  code="$(curl -ks -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $GIT_PASS" \
      "$GIT_API/projects/$proj" 2>/dev/null || echo 000)"
  if [[ "$code" != "200" ]]; then
    warn "  GitLab project '$repo' not found (HTTP $code); skipping webhook registration"
    return 0
  fi

  # Idempotent: reuse an existing hook with the same URL (PUT), else create (POST).
  local body
  body="$(printf '{"url":"%s","token":"%s","merge_requests_events":true,"push_events":true,"enable_ssl_verification":false}' \
      "$webhook_url" "$token")"
  local hooks hook_id
  hooks="$(curl -ks -H "PRIVATE-TOKEN: $GIT_PASS" "$GIT_API/projects/$proj/hooks" 2>/dev/null || true)"
  hook_id="$(printf '%s' "$hooks" \
      | grep -oE "\{[^}]*\"url\":\"${webhook_url//\//\\/}\"[^}]*\}" \
      | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
  if [[ -n "$hook_id" ]]; then
    curl -ks -H "PRIVATE-TOKEN: $GIT_PASS" -H 'Content-Type: application/json' \
      -X PUT "$GIT_API/projects/$proj/hooks/$hook_id" -d "$body" >/dev/null 2>&1 || true
    log "  updated GitLab webhook on '$repo' -> $webhook_url (hook id $hook_id)"
  else
    local resp new_id
    resp="$(curl -ks -H "PRIVATE-TOKEN: $GIT_PASS" -H 'Content-Type: application/json' \
      -X POST "$GIT_API/projects/$proj/hooks" -d "$body" 2>/dev/null || true)"
    new_id="$(printf '%s' "$resp" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
    if [[ -n "$new_id" ]]; then
      log "  created GitLab webhook on '$repo' -> $webhook_url (hook id $new_id)"
    else
      warn "  failed to create GitLab webhook on '$repo': ${resp:-<no response>}"
    fi
  fi
}

# Register a git-backed Porch Repository if not already present. The Porch
# Repository `type:` follows the selected backend (git for Gitea, gitlab for
# GitLab) — set in $GIT_TYPE by apply_git_backend.
ensure_repo_registered() {  # ensure_repo_registered <porch-name> <git-repo> <directory> [deployment]
  local name="$1" git_repo="$2" dir="$3" deployment="${4:-true}"
  local want_url="$GIT_BASE/$git_repo.git"
  if kubectl get repository "$name" -n "$PORCH_NS" >/dev/null 2>&1; then
    local cur_type cur_url cur_secret
    cur_type="$(kubectl get repository "$name" -n "$PORCH_NS" -o jsonpath='{.spec.type}' 2>/dev/null)"
    cur_url="$(kubectl get repository "$name" -n "$PORCH_NS" -o jsonpath='{.spec.git.repo}' 2>/dev/null)"
    cur_secret="$(kubectl get repository "$name" -n "$PORCH_NS" -o jsonpath='{.spec.git.secretRef.name}' 2>/dev/null)"

    # Cross-backend mismatch (different type or a different git server): this
    # region was deployed on another backend. Do NOT silently repoint it — fail
    # fast and tell the user to tear it down first (preserves the earlier
    # backend-consistency contract). assert_repo_backend dies with guidance.
    if [[ "$cur_type" != "$GIT_TYPE" || "$cur_url" != "$want_url" ]]; then
      assert_repo_backend "$name" "$git_repo"
    fi

    # Fully matches the selected backend (type + URL + secret binding) → REUSE it
    # as-is. No churn on re-runs.
    if [[ "$cur_secret" == "$GIT_SECRET" ]]; then
      log "  reusing existing Repository '$name' (type=$GIT_TYPE, secret=$GIT_SECRET)"
      return 0
    fi

    # Same backend/URL but bound to a DIFFERENT secret. Porch caches git
    # credentials on the Repository object, so switching the secret binding won't
    # take effect by patching — delete + recreate so Porch re-reads it.
    log "  recreating Repository '$name' (secret '$cur_secret' -> '$GIT_SECRET')"
    kubectl delete repository "$name" -n "$PORCH_NS" --ignore-not-found >/dev/null 2>&1 || true
    sleep 2
  fi
  log "Registering Porch repository '$name' -> $git_repo.git $dir (type=$GIT_TYPE deployment=$deployment)"
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
  type: $GIT_TYPE
  git:
    repo: $GIT_BASE/$git_repo.git
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
  local region="$1" ns="$2" kubeconfig_secret="${3:-}"
  require porchctl
  local flux_repo="${region}${FLUX_SUFFIX}"          # ireland-flux-config
  local src; src="$(latest_blueprint_rev "$FLUX_BLUEPRINT_NAME")"
  [[ -n "$src" ]] || die "no published $FLUX_BLUEPRINT_NAME; run '$0 flux-blueprint' (or 'all')"

  step "GitOps wiring for '$region' (Flux config package)"
  explain "The app package is now in git, but nothing is watching it yet. We clone" \
          "the flux-blueprint into $flux_repo → /flux-config and stamp it with this" \
          "region's inputs. This wiring tells Flux which repo/path to reconcile and" \
          "which cluster to apply it to (kubeconfigSecret = remote-apply)." \
          "" \
          "Flux wiring blueprint : $src"
  local pr; pr="$(editable_draft "$flux_repo" "$FLUX_PKG_NAME" "clone" "$src")"
  explain "Editable Draft revision: $pr"

  local tmp; tmp="$(mktemp -d)"; local work="$tmp/pkg"
  run_visible p rpkg pull "$pr" "$work" >/dev/null
  local work_orig=""
  if interactive; then work_orig="$tmp/pkg.orig"; cp -r "$work" "$work_orig"; fi
  # The Flux GitRepository points at the region Gitea repo; the app lives in /apps.
  # kubeconfigSecret makes Flux apply the app to the remote (region) cluster.
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
  kubeconfigSecret: $kubeconfig_secret
  gitBase: $GIT_BASE
  gitSecret: $GIT_SECRET
EOF
  if interactive && [[ -n "$work_orig" ]]; then
    show_diff "Flux wiring inputs for $region" "$work_orig" "$work"
    explain "kubeconfigSecret=$kubeconfig_secret → Flux on THIS cluster applies the" \
            "app to the remote region cluster. appPath=apps → it reconciles /apps."
    pause
  fi
  run_visible p rpkg push "$pr" "$work" >/dev/null
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
  step "Bootstrap Flux root for '$region'"
  explain "The final handoff: a root GitRepository + Kustomization ('${region}-flux')" \
          "that watches $region.git → /flux-config. That wiring in turn reconciles" \
          "/apps onto the region cluster. From here on it's pure GitOps — republish" \
          "a package and Flux converges the cluster automatically." \
          "" \
          "Namespace (holds the Flux objects, on mgmt cluster): $ns"
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

  run_visible kubectl apply -f - >/dev/null <<EOF
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
  if interactive; then
    explain "Flux is now reconciling. Current sources/kustomizations in $ns:"
    run_visible flux get sources git -n "$ns" 2>/dev/null | sed 's/^/    /' >&2 || true
    run_visible flux get kustomizations -n "$ns" 2>/dev/null | sed 's/^/    /' >&2 || true
    pause
  fi
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
  all                  Deploy all three regions (ireland, sweden, hungary)
  status               Show blueprints, app + flux packages, and Flux status
  teardown <region>    Tear down one region (Flux root, Porch packages + repo
                       registrations, namespace, RBAC). The backing git repo is
                       left intact.
  teardown --all       Tear down all regions.  Flags: --blueprint --flux --images
  teardown --blueprint Delete ONLY the published blueprints + the blueprints repo
                       registration (no region teardown; backing git repo kept)
  teardown --flux      Uninstall ONLY the Flux controllers (no region teardown)
  teardown --images    Remove ONLY the locally-cached branded images
                       (the three targeted flags can be combined, e.g.
                        teardown --flux --images)

Upgrade (roll a region forward after editing/republishing a blueprint):
  upgrade <region> [--revision <n>] [--store <astronomy|florist>] [--flux]
                       Upgrade a region's APP package via 'rpkg upgrade' (Porch
                       resource-merge, preserves region customizations), then
                       reconcile. Defaults to the LATEST app blueprint; pass
                       --revision <n> (an integer: 1, 2, …) to pin the app package
                       to a specific blueprint revision. Pass --store to re-brand
                       the storefront (astronomy|florist); if omitted the region
                       keeps its current store. The flux wiring package is NOT
                       upgraded by default (it rarely changes) — pass --flux to
                       also upgrade + republish it. (alias: update)
  upgrade-all [--flux] upgrade ireland + sweden + hungary  (alias: update-all)

Other:
  images [store]       Verify the pre-published branded images for a store are
                       resolvable from the registry (astronomy|florist; no build).
  build <astronomy|florist> [cluster ...]
                       Optional: build the branded images locally and kind-load
                       them (tagged into \$IMAGE_REGISTRY) into the given kind
                       clusters — or, if none are named, into every existing kind
                       cluster. For offline use or when iterating on the image
                       sources; a normal deploy pulls from the registry instead.
                       See BUILD_LOCAL below.

Advanced (normally run automatically by a deploy — rarely needed directly):
  blueprint            Publish local app-blueprint/ to '$BLUEPRINT_REPO'
  blueprint-fixed      Publish the NEXT, FIXED blueprint revision by copying the
                       latest published revision in Porch and removing the 'chaos'
                       input entirely (schema + pipeline, always off) so the app
                       runs clean, plus bumping flagd/checkout memory +10Mi (so they
                       restart on upgrade). Demonstrates blueprint evolution — then
                       'upgrade <region>' rolls a region to it. (alias: blueprint-vX)
  flux-blueprint       Publish local flux-blueprint/ to '$BLUEPRINT_REPO'
  flux-init            Install Flux controllers + create/replicate the git secret
  flux-bootstrap       flux-init + ensure the flux blueprint is published

GitOps model: per region there is ONE Gitea repo with two dirs — /apps (the shop,
from app-blueprint) and /flux-config (the Flux wiring, from flux-blueprint), each a
Porch package. A per-region root Kustomization (<region>-flux) watches /flux-config,
which applies /apps. Adding/updating a region = republish its packages via Porch.

Regions: ireland (en-IE/EUR), sweden (sv-SE/SEK), hungary (hu-HU/HUF),
         plus us, india, czech-republic, china.

Interactive / demo mode (works with any command, e.g. a deploy):
  -i, --interactive    Guided walkthrough: pause between stages, explain what KPT
                       and Porch are doing, and show what changes (package
                       lifecycle Draft→Published, KRM diffs, git + Flux state).
  --auto               Same narration but auto-advance (no Enter) — good for
                       recordings/hands-free demos.
  --step-delay <secs>  Auto-advance delay (default 2; implies --auto).
                       (Env equivalents: INTERACTIVE=1, AUTO=1, STEP_DELAY=<secs>.)

Git backend (works with any command, e.g. a deploy):
  --gitBackend <gitea|gitlab>
                       Select the git server Porch stores packages in. Default is
                       gitea (current behavior, unchanged). 'gitlab' switches the
                       Porch Repository type to 'gitlab', points at the GitLab
                       base URL/API, and uses GitLab credentials + secret. Backing
                       repos are auto-created via the matching backend API.
                       (Env equivalent: GIT_BACKEND=gitlab.)
                       GitLab auth: if no token is supplied, deploy.sh reuses a
                       cached PAT and, failing that, auto-provisions a full-scope
                       one from the running '$GITLAB_CONTAINER' container (caching
                       it in the deployment folder as .gitlab-token). Supply
                       GITLAB_TOKEN to skip auto-provisioning.

Env overrides: BLUEPRINT_DIR, FLUX_BLUEPRINT_DIR, PORCH_NS ($PORCH_NS),
  BLUEPRINT_REPO ($BLUEPRINT_REPO), APPS_SUFFIX ($APPS_SUFFIX), FLUX_SUFFIX ($FLUX_SUFFIX),
  GIT_BACKEND ($GIT_BACKEND), GIT_SECRET ($GIT_SECRET), KIND_CLUSTER ($KIND_CLUSTER),
  Gitea:  GITEA_BASE ($GITEA_BASE), GITEA_API ($GITEA_API), GITEA_USER, GITEA_PASS, GITEA_SECRET,
  GitLab: GITLAB_BASE ($GITLAB_BASE), GITLAB_API ($GITLAB_API), GITLAB_USER, GITLAB_SECRET,
          GITLAB_TOKEN (required for --gitBackend gitlab — a Personal Access Token with
          scopes api, read_repository, write_repository; GIT_TOKEN and GITLAB_PASS are
          accepted aliases, precedence GITLAB_TOKEN > GIT_TOKEN > GITLAB_PASS.
          If unset, a token is reused from GITLAB_TOKEN_CACHE ($GITLAB_TOKEN_CACHE)
          or auto-provisioned from the GITLAB_CONTAINER ($GITLAB_CONTAINER) container),
  GitLab webhook: for type=gitlab, deploy.sh registers a Porch SCM webhook on each
          region's GitLab project (merged MRs → Porch). The token secret is
          auto-created (random) if missing and porch-server is restarted to load it.
          Resolved live from the cluster; overrides: WEBHOOK_REGISTER (=0 to skip),
          WEBHOOK_NS ($WEBHOOK_NS), WEBHOOK_LB_SVC ($WEBHOOK_LB_SVC),
          WEBHOOK_SECRET ($WEBHOOK_SECRET), WEBHOOK_SERVER_DEPLOY ($WEBHOOK_SERVER_DEPLOY),
          WEBHOOK_PATH ($WEBHOOK_PATH), WEBHOOK_IP, WEBHOOK_PORT, WEBHOOK_TOKEN,
  IMAGE_REGISTRY ($IMAGE_REGISTRY) — registry namespace for the branded images,
  BUILD_LOCAL (set =1 to build + kind-load images during a deploy instead of pulling).
  Effective git base for the selected backend: $GIT_BASE (type=$GIT_TYPE, secret=$GIT_SECRET).
  Note: the git auth secret is reconciled every run to match the selected backend/token,
  and a region's Repository CR is recreated when needed so Porch re-reads refreshed creds.

Examples:
  $0 ireland                       # deploy ireland (astronomy), gitea backend
  $0 ireland --gitBackend gitlab   # deploy ireland using GitLab (needs GITLAB_TOKEN=<PAT>)
  $0 -i ireland                    # deploy ireland as a guided KPT/Porch walkthrough
  $0 --auto ireland florist        # hands-free narrated demo (florist store)
  $0 sweden florist                # deploy sweden as a florist store
  $0 all --gitBackend gitlab       # deploy all three regions onto GitLab
  $0 upgrade ireland                     # roll ireland forward to the latest blueprints
  $0 upgrade ireland --revision 2        # roll ireland to a specific blueprint revision (2)
  $0 upgrade ireland --store florist     # upgrade + switch the storefront to florist
  $0 teardown ireland              # tear down one region
  $0 teardown --blueprint          # delete ONLY the blueprints (keep regions)
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
  local region_cl; region_cl="$(region_cluster "$region")"
  require kubectl; require porchctl
  kubectl config use-context "$MGMT_CONTEXT" >/dev/null 2>&1 || true
  log "Teardown: region=$region ns=$ns cluster=$region_cl"

  # 1. Delete the per-region Flux root on the MGMT cluster. prune:true garbage-collects
  #    the inner Flux wiring; the inner Kustomization's prune removes remote workloads
  #    (best-effort — the region cluster is deleted in step 4 regardless).
  log "  deleting Flux root ${region}-flux on management cluster"
  kubectl --context "$MGMT_CONTEXT" delete kustomization "${region}-flux" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$MGMT_CONTEXT" delete gitrepository "${region}-flux" -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  sleep 5

  # 2. Delete the Porch packages: flux wiring (in <region>-flux-config) and app (in <region>-apps).
  log "  deleting Porch package $FLUX_PKG_NAME in $flux_repo"
  delete_porch_pkg_revisions "$flux_repo" "$FLUX_PKG_NAME"
  log "  deleting Porch package $PACKAGE_NAME in $apps_repo"
  delete_porch_pkg_revisions "$apps_repo" "$PACKAGE_NAME"

  # 2b. Delete the Porch Repository registrations themselves so the region is fully
  #     unregistered (not just emptied). This also clears the backend binding, so a
  #     subsequent deploy can register the region on a different git backend
  #     (--gitBackend). The BACKING git repo (Gitea repo / GitLab project) is left
  #     intact — only the Porch registration is removed.
  log "  deleting Porch repositories $apps_repo, $flux_repo"
  kubectl --context "$MGMT_CONTEXT" delete repository "$apps_repo" -n "$PORCH_NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$MGMT_CONTEXT" delete repository "$flux_repo" -n "$PORCH_NS" --ignore-not-found >/dev/null 2>&1 || true

  # 3. Delete the region namespace + kubeconfig secret on the MGMT cluster (Flux objects lived here).
  kubectl --context "$MGMT_CONTEXT" delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # 4. Delete the region workload cluster entirely (removes all workloads + its RBAC).
  if kind get clusters 2>/dev/null | grep -qx "$region_cl"; then
    log "  deleting region kind cluster $region_cl"
    kind delete cluster --name "$region_cl" >/dev/null 2>&1 || true
  fi
  log "Teardown complete for $region"
}

delete_blueprint() {
  require porchctl
  resolve_blueprint_repo
  log "Deleting blueprint revisions in $BLUEPRINT_REPO ($BLUEPRINT_NAME, $FLUX_BLUEPRINT_NAME)"
  delete_porch_pkg_revisions "$BLUEPRINT_REPO" "$BLUEPRINT_NAME"
  delete_porch_pkg_revisions "$BLUEPRINT_REPO" "$FLUX_BLUEPRINT_NAME"
  # Also unregister the shared blueprints Porch Repository so it can be re-created
  # on a different backend later. The backing git repo is left intact.
  log "  deleting Porch repository $BLUEPRINT_REPO"
  kubectl --context "$MGMT_CONTEXT" delete repository "$BLUEPRINT_REPO" -n "$PORCH_NS" --ignore-not-found >/dev/null 2>&1 || true
}

uninstall_flux() {
  require flux
  warn "Uninstalling Flux controllers from the cluster"
  flux uninstall --silent >/dev/null 2>&1 || true
  log "Flux uninstalled"
}

remove_images() {
  require docker
  log "Removing locally-cached registry images ($IMAGE_REGISTRY, tag :$IMAGE_TAG)"
  for img in astronomy-frontend astronomy-ad astronomy-llm astronomy-email \
             florist-frontend florist-ad florist-llm florist-image-provider \
             florist-load-generator email; do
    docker rmi "$IMAGE_REGISTRY/$img:$IMAGE_TAG" >/dev/null 2>&1 && log "  removed $IMAGE_REGISTRY/$img:$IMAGE_TAG" || true
  done
}



# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
# Pre-parse global flags (allowed anywhere in the args):
#   -i | --interactive   guided walkthrough with pauses + narration
#   --auto               interactive narration, but auto-advance (no Enter needed)
#   --step-delay <secs>  auto-advance delay (implies --auto)
_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interactive) INTERACTIVE=1 ;;
    --auto)           INTERACTIVE=1; AUTO=1 ;;
    --step-delay)     INTERACTIVE=1; AUTO=1; STEP_DELAY="${2:-2}"; shift ;;
    --gitBackend|--git-backend)
                      GIT_BACKEND="${2:-}"; GIT_BACKEND_EXPLICIT=1; shift ;;
    --gitBackend=*|--git-backend=*)
                      GIT_BACKEND="${1#*=}"; GIT_BACKEND_EXPLICIT=1 ;;
    *)                _args+=("$1") ;;
  esac
  shift
done
set -- "${_args[@]}"

# Re-resolve the effective GIT_* values now that --gitBackend has been parsed
# (validates the value and dies on anything other than gitea|gitlab).
apply_git_backend

# Announce the walkthrough (no-op unless interactive).
interactive_intro

cmd="${1:-}"; shift || true
case "$cmd" in
  build)
    [[ $# -ge 1 ]] || die "usage: $0 build <astronomy|florist> [cluster ...]"
    store="$1"; shift
    if [[ $# -ge 1 ]]; then
      # explicit target clusters
      build_images "$store" "$@"
    else
      # default: load into every existing kind cluster (that's where workloads run)
      mapfile -t _clusters < <(kind get clusters 2>/dev/null | grep -v '^[[:space:]]*$')
      if [[ ${#_clusters[@]} -eq 0 ]]; then
        die "no kind clusters exist yet — create one (deploy a region) or pass a cluster name: $0 build $store <cluster>"
      fi
      build_images "$store" "${_clusters[@]}"
    fi
    ;;
  images)     check_images "${1:-astronomy}" ;;
  blueprint)  push_blueprint ;;
  blueprint-fixed|blueprint-vX) push_blueprint_fixed ;;
  flux-blueprint) push_flux_blueprint ;;
  deploy)     [[ $# -ge 1 ]] || die "usage: $0 deploy <region> [store]"; deploy_target "$@" ;;
  flux-init)  flux_init ;;
  flux-bootstrap) flux_bootstrap ;;
  status)     status ;;
  upgrade|update)
    [[ $# -ge 1 ]] || die "usage: $0 upgrade <region> [--revision <n>] [--store <astronomy|florist>] [--flux]"
    _region=""; _rev=""; _store=""; _flux=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --revision) _rev="${2:-}"; shift 2 ;;
        --revision=*) _rev="${1#*=}"; shift ;;
        --store) _store="${2:-}"; shift 2 ;;
        --store=*) _store="${1#*=}"; shift ;;
        --flux|--with-flux) _flux=1; shift ;;
        -*) die "unknown flag '$1' (usage: $0 upgrade <region> [--revision <n>] [--store <astronomy|florist>] [--flux])" ;;
        *) [[ -z "$_region" ]] && _region="$1" || die "unexpected argument '$1'"; shift ;;
      esac
    done
    [[ -n "$_region" ]] || die "usage: $0 upgrade <region> [--revision <n>] [--store <astronomy|florist>] [--flux]"
    upgrade_region "$_region" "$_rev" "$_store" "$_flux"
    ;;
  upgrade-all|update-all)
    _flux=0
    for a in "$@"; do [[ "$a" == "--flux" || "$a" == "--with-flux" ]] && _flux=1; done
    upgrade_region ireland "" "" "$_flux"
    upgrade_region sweden  "" "" "$_flux"
    upgrade_region hungary "" "" "$_flux"
    log "Upgrade-all complete."
    ;;
  teardown)
    [[ $# -ge 1 ]] || die "usage: $0 teardown <region> | --all [--blueprint --flux --images] | --blueprint | --flux | --images"
    if [[ "$1" == --all || "$1" == all ]]; then
      shift
      teardown_target ireland; teardown_target sweden; teardown_target hungary
      for arg in "$@"; do
        case "$arg" in
          --blueprint|--blueprints) delete_blueprint ;;
          --flux)                   uninstall_flux ;;
          --image|--images)         remove_images ;;
          *) warn "unknown teardown flag: $arg" ;;
        esac
      done
      log "Teardown-all complete."
    elif [[ "$1" == -* ]]; then
      # Flags-only teardown: remove just blueprints / flux / images, WITHOUT
      # tearing down any region. e.g.  $0 teardown --blueprint
      #                                $0 teardown --flux --images
      did=0
      for arg in "$@"; do
        case "$arg" in
          --blueprint|--blueprints) delete_blueprint; did=1 ;;
          --flux)                   uninstall_flux;   did=1 ;;
          --image|--images)         remove_images;    did=1 ;;
          *) die "'$arg' is not valid. Use a region name, --all, or one of --blueprint/--flux/--images" ;;
        esac
      done
      [[ "$did" == 1 ]] || die "nothing to do"
      log "Teardown (targeted) complete."
    else
      teardown_target "$1"
    fi
    ;;
  teardown-all)
    teardown_target ireland
    teardown_target sweden
    teardown_target hungary
    for arg in "$@"; do
      case "$arg" in
        --blueprint|--blueprints) delete_blueprint ;;
        --flux)                   uninstall_flux ;;
        --image|--images)         remove_images ;;
        *) warn "unknown teardown-all flag: $arg" ;;
      esac
    done
    log "Teardown-all complete."
    ;;
  all)
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
