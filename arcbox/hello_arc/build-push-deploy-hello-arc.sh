#!/usr/bin/env bash
set -euo pipefail

# Build the hello-arc image, push to ACR, and deploy to an Arc-enabled cluster.
# Uses az to obtain ACR credentials and az connectedk8s proxy for deployment.

CLUSTER_NAME_DEFAULT="ArcDev-K3s-Data-3ff7"
RESOURCE_GROUP_DEFAULT="arc-devops-demo"
ACR_NAME_DEFAULT="ctecharcdemoACR"
CONNECTED_REGISTRY_NAME_DEFAULT="ctecharcdemoConnectedRegistry"

CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME_DEFAULT}"
RESOURCE_GROUP="${RESOURCE_GROUP:-$RESOURCE_GROUP_DEFAULT}"
ACR_NAME="${ACR_NAME:-$ACR_NAME_DEFAULT}"
CONNECTED_REGISTRY_NAME="${CONNECTED_REGISTRY_NAME:-$CONNECTED_REGISTRY_NAME_DEFAULT}"
ACR_NAME_LOWER="$(printf '%s' "$ACR_NAME" | tr '[:upper:]' '[:lower:]')"

NAMESPACE_DEFAULT="hello-arc"
RELEASE_NAME_DEFAULT="hello-arc"
IMAGE_NAME_DEFAULT="hello-arc"

NAMESPACE="${NAMESPACE:-$NAMESPACE_DEFAULT}"
RELEASE_NAME="${RELEASE_NAME:-$RELEASE_NAME_DEFAULT}"
IMAGE_NAME="${IMAGE_NAME:-$IMAGE_NAME_DEFAULT}"
TAG="${TAG:-}"  # if empty, will auto-generate

PROXY_READY_TIMEOUT_SECONDS="${PROXY_READY_TIMEOUT_SECONDS:-180}"
PROXY_PORT="${PROXY_PORT:-}"
DEPLOY_WITH_HELM="${DEPLOY_WITH_HELM:-false}"
USE_LOCAL_DOCKER="${USE_LOCAL_DOCKER:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-$SCRIPT_DIR/app}"
CHART_DIR="${CHART_DIR:-$SCRIPT_DIR/charts/hello-arc}"

log() { printf '%s\n' "[$(date -Is)] $*"; }

die() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_cmd az
if [[ "${DEPLOY_WITH_HELM:-false}" == "true" ]]; then
  require_cmd helm
  require_cmd kubectl
  require_cmd python3
fi

[[ -d "$APP_DIR" ]] || die "App directory not found: $APP_DIR"
[[ -d "$CHART_DIR" ]] || die "Chart directory not found: $CHART_DIR"

# Avoid interactive prompts when az wants to install extensions.
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
az config set extension.dynamic_install_allow_preview=true >/dev/null

# Fail fast if the user isn't logged in.
if ! az account show >/dev/null 2>&1; then
  die "Not logged into Azure CLI. Run: az login"
fi

if [[ "$DEPLOY_WITH_HELM" == "true" ]]; then
  log "Ensuring Azure CLI connectedk8s extension is installed"
  az extension add --name connectedk8s >/dev/null
fi

log "Resolving ACR login server"
ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME_LOWER" -g "$RESOURCE_GROUP" --query loginServer -o tsv)"
[[ -n "$ACR_LOGIN_SERVER" ]] || die "Unable to resolve ACR loginServer for $ACR_NAME"

if [[ -z "$TAG" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$APP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    TAG="$(git -C "$APP_DIR" rev-parse --short HEAD)"
  else
    TAG="$(date +%Y%m%d%H%M%S)"
  fi
fi

IMAGE_FULL="$ACR_LOGIN_SERVER/$IMAGE_NAME:$TAG"

if [[ "$USE_LOCAL_DOCKER" == "true" ]]; then
  require_cmd docker

  log "Checking Docker engine availability"
  if ! docker info >/dev/null 2>&1; then
    die "Docker engine is not reachable. Either start Docker (e.g. systemctl start docker) or rerun with USE_LOCAL_DOCKER=false (default) to use az acr build."
  fi

  log "Logging in to ACR (local Docker)"
  # Preferred: az acr login (uses Docker credential helper). If that fails, fall back to token-based docker login.
  set +e
  acr_login_err="$(az acr login --name "$ACR_NAME_LOWER" 2>&1)"
  acr_login_rc=$?
  set -e

  if [[ $acr_login_rc -ne 0 ]]; then
    log "az acr login failed; falling back to token-based docker login"
    printf '%s\n' "$acr_login_err" >&2 || true
    access_token="$(az acr login --name "$ACR_NAME_LOWER" --expose-token --query accessToken -o tsv)"
    [[ -n "${access_token:-}" ]] || die "Failed to obtain ACR access token"
    docker login "$ACR_LOGIN_SERVER" \
      --username 00000000-0000-0000-0000-000000000000 \
      --password "$access_token" >/dev/null
  fi

  log "Building image: $IMAGE_FULL"
  docker build -t "$IMAGE_FULL" -f "$APP_DIR/Dockerfile" "$APP_DIR"

  log "Pushing image: $IMAGE_FULL"
  docker push "$IMAGE_FULL"
else
  log "Building and pushing with ACR Tasks (az acr build): $IMAGE_FULL"
  az acr build \
    --registry "$ACR_NAME_LOWER" \
    --resource-group "$RESOURCE_GROUP" \
    --image "$IMAGE_NAME:$TAG" \
    --file "$APP_DIR/Dockerfile" \
    "$APP_DIR"
fi

if [[ "$DEPLOY_WITH_HELM" == "true" ]]; then
  # Determine the preferred pull endpoint for the cluster (connected registry if available).
  PULL_REGISTRY="$ACR_LOGIN_SERVER"
  if [[ -n "${CONNECTED_REGISTRY_NAME:-}" ]]; then
    set +e
    connected_login_server="$(az acr connected-registry show -r "$ACR_NAME_LOWER" -g "$RESOURCE_GROUP" -n "$CONNECTED_REGISTRY_NAME" --query loginServer -o tsv 2>/dev/null)"
    set -e
    if [[ -n "${connected_login_server:-}" && "${connected_login_server:-}" != "None" ]]; then
      PULL_REGISTRY="$connected_login_server"
    fi
  fi

  DEPLOY_IMAGE_REPO="$PULL_REGISTRY/$IMAGE_NAME"
fi

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

if [[ "$DEPLOY_WITH_HELM" == "true" ]]; then
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

  log "Deploying Helm chart"
  helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" --create-namespace \
    --kubeconfig "$kubeconfig_file" \
    --set "image.repository=$DEPLOY_IMAGE_REPO" \
    --set "image.tag=$TAG"

  log "Deployment rollout status"
  set +e
  kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" rollout status deploy/hello-arc --timeout=180s
  set -e

  log "Pods"
  kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE" get pods -o wide || true
else
  # For GitOps: workloads typically pull from the Connected Registry loginServer, not the ACR loginServer.
  gitops_registry="$ACR_LOGIN_SERVER"
  if [[ -n "${CONNECTED_REGISTRY_NAME:-}" ]]; then
    set +e
    connected_login_server="$(az acr connected-registry show -r "$ACR_NAME_LOWER" -g "$RESOURCE_GROUP" -n "$CONNECTED_REGISTRY_NAME" --query loginServer -o tsv 2>/dev/null)"
    set -e
    if [[ -n "${connected_login_server:-}" && "${connected_login_server:-}" != "None" ]]; then
      gitops_registry="$connected_login_server"
    fi
  fi

  log "Skipping Helm deployment (DEPLOY_WITH_HELM=false)"
  log "Pushed image: $IMAGE_FULL"
  log "For GitOps, set image.repository=$gitops_registry/$IMAGE_NAME and image.tag=$TAG"
fi

log "Done"
