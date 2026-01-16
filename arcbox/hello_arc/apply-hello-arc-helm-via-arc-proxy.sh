#!/usr/bin/env bash
set -euo pipefail

# Apply the local hello-arc Helm chart directly to an Arc-enabled Kubernetes cluster
# via `az connectedk8s proxy`.
#
# This is intentionally "out of band" from GitOps so you can demonstrate configuration drift.

CLUSTER_NAME_DEFAULT="ArcDev-K3s-Data-3ff7"
RESOURCE_GROUP_DEFAULT="arc-devops-demo"
# Default to the namespace used by the plain YAML example in this repo.
# For the GitOps (Flux) HelmRelease example, override with: NAMESPACE=prod RELEASE_NAME=hello-arc-prod
NAMESPACE_DEFAULT="hello-arc"
RELEASE_NAME_DEFAULT="hello-arc"

CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME_DEFAULT}"
RESOURCE_GROUP="${RESOURCE_GROUP:-$RESOURCE_GROUP_DEFAULT}"
NAMESPACE="${NAMESPACE:-$NAMESPACE_DEFAULT}"
RELEASE_NAME="${RELEASE_NAME:-$RELEASE_NAME_DEFAULT}"

# Optional overrides to create drift.
MESSAGE="${MESSAGE:-Direct Helm apply (drift) $(date -Is)}"
REPLICA_COUNT="${REPLICA_COUNT:-}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-}"
IMAGE_TAG="${IMAGE_TAG:-}"

# Ownership behavior when resources already exist in the target namespace.
# - auto: if a Service with the expected name exists but is not Helm-owned, add `--take-ownership`.
# - true: always add `--take-ownership`.
# - false: never add it (script will fail if resources already exist and are not Helm-owned).
TAKE_OWNERSHIP="${TAKE_OWNERSHIP:-auto}"

# When adopting existing resources that were created outside Helm, deployments may need to be
# deleted/recreated due to immutable fields (like `.spec.selector`).
# - auto: if a Deployment with the expected name exists but is not Helm-owned, add `--force`.
# - true: always add `--force`.
# - false: never add it.
FORCE_RECREATE="${FORCE_RECREATE:-auto}"

# If the target namespace already has a legacy (non-Helm) deployment with selector `app=hello-arc`,
# the chart must match that selector to avoid immutable `.spec.selector` changes.
# - auto: detect legacy selector and set `selector.useLegacyAppLabel=true`.
# - true: always set it.
# - false: never set it.
USE_LEGACY_SELECTOR="${USE_LEGACY_SELECTOR:-auto}"

# Behavior toggles
DRY_RUN="${DRY_RUN:-false}"
WAIT="${WAIT:-true}"
TIMEOUT="${TIMEOUT:-10m}"
PROXY_READY_TIMEOUT_SECONDS="${PROXY_READY_TIMEOUT_SECONDS:-180}"
PROXY_PORT="${PROXY_PORT:-}"

log() { printf '%s\n' "[$(date -Is)] $*"; }

die() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_cmd az
require_cmd helm
require_cmd kubectl
require_cmd python3

# Avoid interactive prompts when az wants to install extensions.
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
az config set extension.dynamic_install_allow_preview=true >/dev/null

log "Ensuring Azure CLI connectedk8s extension is installed"
az extension add --name connectedk8s >/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${CHART_DIR:-$SCRIPT_DIR/charts/hello-arc}"
[[ -d "$CHART_DIR" ]] || die "Chart directory not found: $CHART_DIR"

kubeconfig_file=""
proxy_log=""
proxy_pid=""

cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  if [[ -n "${proxy_pid:-}" ]] && kill -0 "$proxy_pid" >/dev/null 2>&1; then
    log "Stopping Arc proxy (pid=$proxy_pid)"
    kill "$proxy_pid" >/dev/null 2>&1 || true
    wait "$proxy_pid" >/dev/null 2>&1 || true
  fi
  [[ -n "${kubeconfig_file:-}" ]] && rm -f "$kubeconfig_file" >/dev/null 2>&1 || true
  [[ -n "${proxy_log:-}" ]] && rm -f "$proxy_log" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

kubeconfig_file="$(mktemp -t kubeconfig.arcproxy.XXXXXX.yaml)"
proxy_log="$(mktemp -t connectedk8s-proxy.XXXXXX.log)"

if [[ -z "${PROXY_PORT:-}" ]]; then
  PROXY_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
PY
)"
fi

log "Starting az connectedk8s proxy (cluster=$CLUSTER_NAME rg=$RESOURCE_GROUP port=$PROXY_PORT)"
az connectedk8s proxy \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --port "$PROXY_PORT" \
  --file "$kubeconfig_file" \
  --kube-context "$CLUSTER_NAME" \
  >"$proxy_log" 2>&1 &
proxy_pid=$!

log "Waiting for Arc proxy to become ready"
start_epoch=$(date +%s)
last_kubectl_err=""
while true; do
  if ! kill -0 "$proxy_pid" >/dev/null 2>&1; then
    log "Arc proxy process exited unexpectedly. Output:"
    sed -n '1,200p' "$proxy_log" >&2 || true
    die "Arc proxy failed to start"
  fi

  if [[ -s "$kubeconfig_file" ]]; then
    set +e
    last_kubectl_err="$(kubectl --kubeconfig "$kubeconfig_file" get --raw='/version' 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      break
    fi
  fi

  now_epoch=$(date +%s)
  if (( now_epoch - start_epoch > PROXY_READY_TIMEOUT_SECONDS )); then
    log "Timed out waiting for Arc proxy readiness. Output:"
    sed -n '1,200p' "$proxy_log" >&2 || true
    if [[ -n "${last_kubectl_err:-}" ]]; then
      log "Last kubectl error:"
      printf '%s\n' "$last_kubectl_err" >&2 || true
    fi
    die "Timed out waiting for Arc proxy"
  fi
  sleep 2
done

log "Proxy ready. Current cluster context:"
kubectl --kubeconfig "$kubeconfig_file" cluster-info

take_ownership_flag=""
force_flag=""
use_legacy_selector="false"
legacy_app_label_value=""
if [[ "$TAKE_OWNERSHIP" == "true" ]]; then
  take_ownership_flag="--take-ownership"
elif [[ "$TAKE_OWNERSHIP" == "auto" ]]; then
  # This chart's Service name typically equals the Helm release name (because the release name contains the chart name).
  # If a pre-existing Service is present but not Helm-owned, `helm install` will fail unless we take ownership.
  set +e
  kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get svc "$RELEASE_NAME" >/dev/null 2>&1
  svc_exists=$?
  set -e
  if [[ $svc_exists -eq 0 ]]; then
    set +e
    existing_owner="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get svc "$RELEASE_NAME" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
    existing_release_name="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get svc "$RELEASE_NAME" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)"
    existing_release_ns="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get svc "$RELEASE_NAME" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null)"
    set -e

    if [[ "$existing_owner" != "Helm" || "$existing_release_name" != "$RELEASE_NAME" || "$existing_release_ns" != "$NAMESPACE" ]]; then
      log "Detected existing Service '$RELEASE_NAME' in namespace '$NAMESPACE' that is not Helm-owned; enabling --take-ownership"
      take_ownership_flag="--take-ownership"
    fi
  fi
elif [[ "$TAKE_OWNERSHIP" != "false" ]]; then
  die "Invalid TAKE_OWNERSHIP value: $TAKE_OWNERSHIP (expected: auto|true|false)"
fi

if [[ "$FORCE_RECREATE" == "true" ]]; then
  force_flag="--force"
elif [[ "$FORCE_RECREATE" == "auto" ]]; then
  set +e
  kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy "$RELEASE_NAME" >/dev/null 2>&1
  deploy_exists=$?
  set -e
  if [[ $deploy_exists -eq 0 ]]; then
    set +e
    existing_owner="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy "$RELEASE_NAME" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
    existing_release_name="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy "$RELEASE_NAME" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)"
    existing_release_ns="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy "$RELEASE_NAME" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null)"
    set -e

    if [[ "$existing_owner" != "Helm" || "$existing_release_name" != "$RELEASE_NAME" || "$existing_release_ns" != "$NAMESPACE" ]]; then
      log "Detected existing Deployment '$RELEASE_NAME' in namespace '$NAMESPACE' that is not Helm-owned; enabling --force (recreate on immutable fields)"
      force_flag="--force"
    fi
  fi
elif [[ "$FORCE_RECREATE" != "false" ]]; then
  die "Invalid FORCE_RECREATE value: $FORCE_RECREATE (expected: auto|true|false)"
fi

if [[ "$USE_LEGACY_SELECTOR" == "true" ]]; then
  use_legacy_selector="true"
  legacy_app_label_value="hello-arc"
elif [[ "$USE_LEGACY_SELECTOR" == "auto" ]]; then
  set +e
  legacy_app_selector="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy "$RELEASE_NAME" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null)"
  legacy_kube_app_name_selector="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy "$RELEASE_NAME" -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}' 2>/dev/null)"
  set -e

  if [[ -n "${legacy_app_selector:-}" && -z "${legacy_kube_app_name_selector:-}" ]]; then
    log "Detected legacy deployment selector (app=$legacy_app_selector); enabling selector.useLegacyAppLabel=true"
    use_legacy_selector="true"
    legacy_app_label_value="$legacy_app_selector"
  fi
elif [[ "$USE_LEGACY_SELECTOR" != "false" ]]; then
  die "Invalid USE_LEGACY_SELECTOR value: $USE_LEGACY_SELECTOR (expected: auto|true|false)"
fi

log "Applying local Helm chart directly (this will create drift if GitOps manages the same release)"
helm_args=(
  upgrade --install "$RELEASE_NAME" "$CHART_DIR"
  --namespace "$NAMESPACE" --create-namespace
  --kubeconfig "$kubeconfig_file"
  --set "env.value=$MESSAGE"
)

if [[ -n "$take_ownership_flag" ]]; then
  helm_args+=("$take_ownership_flag")
fi

if [[ -n "$force_flag" ]]; then
  helm_args+=("$force_flag")
fi

if [[ "$use_legacy_selector" == "true" ]]; then
  helm_args+=(--set "selector.useLegacyAppLabel=true")
  if [[ -n "${legacy_app_label_value:-}" ]]; then
    helm_args+=(--set "selector.legacyAppLabel=$legacy_app_label_value")
  fi
fi

if [[ -n "${REPLICA_COUNT:-}" ]]; then
  helm_args+=(--set "replicaCount=$REPLICA_COUNT")
fi
if [[ -n "${IMAGE_REPOSITORY:-}" ]]; then
  helm_args+=(--set "image.repository=$IMAGE_REPOSITORY")
fi
if [[ -n "${IMAGE_TAG:-}" ]]; then
  helm_args+=(--set "image.tag=$IMAGE_TAG")
fi

if [[ "$WAIT" == "true" ]]; then
  helm_args+=(--wait --timeout "$TIMEOUT")
fi
if [[ "$DRY_RUN" == "true" ]]; then
  helm_args+=(--dry-run)
fi

helm "${helm_args[@]}"

log "Helm status (release=$RELEASE_NAME ns=$NAMESPACE)"
helm --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" status "$RELEASE_NAME" || true

log "Deployment rollout status"
set +e
kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" rollout status deploy/hello-arc --timeout=120s
set -e

log "Current workload snapshot (labels: app.kubernetes.io/instance=$RELEASE_NAME)"
if [[ "$use_legacy_selector" == "true" ]]; then
  resource_selector="app=$legacy_app_label_value"
  log "Current workload snapshot (labels: $resource_selector)"
else
  resource_selector="app.kubernetes.io/instance=$RELEASE_NAME"
  log "Current workload snapshot (labels: $resource_selector)"
fi
kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy,svc,ingress -l "$resource_selector" -o wide || true

log "Pods (wide)"
kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get pods -l "$resource_selector" -o wide || true

log "Container readiness / restarts"
kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get pods -l "$resource_selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.name}{":"}{.ready}{" restarts="}{.restartCount}{"\t"}{end}{"\n"}{end}' || true

log "Service endpoints"
kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get endpoints hello-arc -o wide || true

log "Current MESSAGE env in deployment pods:"
selector="$resource_selector"
# Print env from the first matching deployment (if any)
set +e
deployment_name="$(kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
set -e
if [[ -n "${deployment_name:-}" ]]; then
  kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get deploy "$deployment_name" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MESSAGE")].value}'
  printf '\n'
else
  log "No deployment found for selector: $selector"
fi

log "Done (proxy will be stopped automatically)"
