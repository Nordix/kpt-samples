# Source this from the repo root:  source deployment/otel-env.sh
# (or from anywhere:  source ~/kpt-samples/otel-demo/deployment/otel-env.sh)
#
# Sets all environment variables the MANUAL.md runbook expects. Sourcing a file
# avoids pasting the big env block (which some terminals mangle).

# --- where you cloned/copied this project (repo ROOT) ---
# Resolve the repo root as the parent of this file's directory (deployment/),
# so it's correct regardless of where you source it from.
_OTEL_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export REPO="$(cd "$_OTEL_ENV_DIR/.." && pwd)"
unset _OTEL_ENV_DIR

# --- clusters / namespaces ---
export PORCH_NS=porch-demo                 # namespace Porch resources live in (mgmt cluster)
export FLUX_NS=flux-system                 # namespace Flux controllers live in (mgmt cluster)
export MGMT_CLUSTER=porch-test             # kind name of the management cluster
export MGMT_CONTEXT=kind-${MGMT_CLUSTER}   # kubectl context for the management cluster

# --- Gitea backend ---
export GITEA_HOST=172.18.255.204:3000
export GITEA_ORG=porch                     # Gitea user/org that owns the repos
export GITEA_USER=porch                    # API + git basic-auth username
export GITEA_PASS=secret                   # API + git basic-auth password/token
export GIT_BASE=http://${GITEA_HOST}/${GITEA_ORG}
export GITEA_API=http://${GITEA_HOST}/api/v1
export GIT_SECRET=gitea                    # k8s Secret name (basic-auth)

# --- fixed package names (usually leave as-is) ---
export BLUEPRINT_REPO=blueprints
export APP_BLUEPRINT=otel-demo-blueprint
export FLUX_BLUEPRINT=flux-blueprint
export APP_PKG=otel-demo              # app package name in <region>-apps
export FLUX_PKG=flux                       # flux package name in <region>-flux-config

# --- the region you are deploying (override as needed) ---
export REGION=${REGION:-sweden}            # us|india|czech-republic|china|ireland|sweden|hungary
export STORE=${STORE:-florist}             # astronomy | florist
export NS=${REGION}-otel-demo              # deployment namespace (mgmt + region cluster)
export REGION_CLUSTER=${REGION}            # kind name of the region workload cluster
export REGION_CONTEXT=kind-${REGION_CLUSTER}
export KUBECONFIG_SECRET=${REGION}-kubeconfig  # Secret (on mgmt) with region kubeconfig

echo "otel-env loaded: REPO=$REPO REGION=$REGION STORE=$STORE PORCH_NS=$PORCH_NS"
