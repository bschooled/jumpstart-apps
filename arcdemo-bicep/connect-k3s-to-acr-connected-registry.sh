#!/usr/bin/env bash
set -euo pipefail

# Connect an Azure Arc-enabled K3s cluster to an Azure Container Registry (ACR) Connected Registry
# by deploying the Connected Registry Arc extension.
#
# Defaults are based on arcdemo-bicep/command-reference.sh.

CLUSTER_NAME_DEFAULT="ArcDev-K3s-Data-3ff7"
RESOURCE_GROUP_DEFAULT="arc-devops-demo"
ACR_NAME_DEFAULT="ctecharcdemoACR"
CONNECTED_REGISTRY_NAME_DEFAULT="ctecharcdemoConnectedRegistry"

CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME_DEFAULT}"
RESOURCE_GROUP="${RESOURCE_GROUP:-$RESOURCE_GROUP_DEFAULT}"
ACR_NAME="${ACR_NAME:-$ACR_NAME_DEFAULT}"
CONNECTED_REGISTRY_NAME="${CONNECTED_REGISTRY_NAME:-$CONNECTED_REGISTRY_NAME_DEFAULT}"

# Azure Arc Connected Registry extension name (can be any name; using the connected registry name keeps it obvious).
EXTENSION_NAME="${EXTENSION_NAME:-$CONNECTED_REGISTRY_NAME}"

# For K3s, service IPs are commonly in 10.43.0.0/16; we try to auto-pick based on the existing
# kubernetes service ClusterIP if kubectl is connected.
SERVICE_CLUSTER_IP="${SERVICE_CLUSTER_IP:-}"  # e.g. 10.43.0.250
STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-}"  # optional, e.g. local-path
VALIDATE_WITH_KUBECTL="${VALIDATE_WITH_KUBECTL:-true}"
PROXY_PORT="${PROXY_PORT:-}"
DISCOVER_WITH_ARC_PROXY="${DISCOVER_WITH_ARC_PROXY:-true}"
USE_LOCAL_KUBECTL_DISCOVERY="${USE_LOCAL_KUBECTL_DISCOVERY:-false}"

log() { printf '%s\n' "[$(date -Is)] $*"; }

die() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

protected_file=""
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
  [[ -n "${protected_file:-}" ]] && rm -f "$protected_file" >/dev/null 2>&1 || true
  [[ -n "${kubeconfig_file:-}" ]] && rm -f "$kubeconfig_file" >/dev/null 2>&1 || true
  [[ -n "${proxy_log:-}" ]] && rm -f "$proxy_log" >/dev/null 2>&1 || true
  exit "$rc"
}

trap cleanup EXIT

require_cmd az
require_cmd python3

start_arc_proxy() {
  local context_label="$1"
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

  log "Starting az connectedk8s proxy ($context_label) on port $PROXY_PORT"
  az connectedk8s proxy \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --port "$PROXY_PORT" \
    --file "$kubeconfig_file" \
    --kube-context "$CLUSTER_NAME" \
    >"$proxy_log" 2>&1 &
  proxy_pid=$!

  log "Waiting for Arc proxy readiness"
  ready_timeout_seconds="${PROXY_READY_TIMEOUT_SECONDS:-180}"
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
    if (( now_epoch - start_epoch > ready_timeout_seconds )); then
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
}

# Avoid interactive prompts when az wants to install extensions.
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
# Connected Registry Arc extension often rides preview trains.
az config set extension.dynamic_install_allow_preview=true >/dev/null

log "Ensuring Azure CLI extensions are installed"
az extension add --name k8s-extension >/dev/null
az extension add --name connectedk8s >/dev/null

log "Ensuring required Azure resource providers are registered"
for rp in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
  az provider register --namespace "$rp" >/dev/null
done

log "Validating ACR and connected registry exist"
az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query name -o tsv >/dev/null
az acr connected-registry show -r "$ACR_NAME" -g "$RESOURCE_GROUP" -n "$CONNECTED_REGISTRY_NAME" --query name -o tsv >/dev/null

log "Ensuring ACR dedicated data endpoint is enabled (required for connected registries)"
if [[ "$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query dataEndpointEnabled -o tsv)" != "true" ]]; then
  az acr update -n "$ACR_NAME" -g "$RESOURCE_GROUP" --data-endpoint-enabled >/dev/null
fi

# Discover service IP/storage class using the Arc proxy (preferred) to ensure we target the correct cluster.
if [[ "$DISCOVER_WITH_ARC_PROXY" == "true" && ( -z "$SERVICE_CLUSTER_IP" || -z "$STORAGE_CLASS_NAME" ) ]] && command -v kubectl >/dev/null 2>&1; then
  start_arc_proxy "for discovery"

  if [[ -z "$SERVICE_CLUSTER_IP" ]]; then
    set +e
    kube_svc_ip="$(kubectl --kubeconfig "$kubeconfig_file" get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
    set -e
    if [[ -n "${kube_svc_ip:-}" ]]; then
      base_prefix="${kube_svc_ip%.*}"
      candidate_ip="${base_prefix}.250"
      # Ensure candidate IP isn't already in use by another Service
      set +e
      svc_conflict="$(kubectl --kubeconfig "$kubeconfig_file" get svc -A -o jsonpath="{range .items[?(@.spec.clusterIP=='$candidate_ip')]}{.metadata.namespace}/{.metadata.name}{'\n'}{end}" 2>/dev/null)"
      set -e
      if [[ -z "${svc_conflict:-}" ]]; then
        SERVICE_CLUSTER_IP="$candidate_ip"
        log "Auto-selected SERVICE_CLUSTER_IP=$SERVICE_CLUSTER_IP based on kubernetes service IP ($kube_svc_ip)"
      else
        log "SERVICE_CLUSTER_IP candidate $candidate_ip is already in use by: ${svc_conflict//$'\n'/, }"
      fi
    fi
  fi

  if [[ -z "$STORAGE_CLASS_NAME" ]]; then
    set +e
    default_sc="$(kubectl --kubeconfig "$kubeconfig_file" get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n 1)"
    set -e

    set +e
    kubectl --kubeconfig "$kubeconfig_file" get sc local-path >/dev/null 2>&1
    local_path_rc=$?
    set -e

    if [[ $local_path_rc -eq 0 ]]; then
      STORAGE_CLASS_NAME="local-path"
      log "Auto-selected STORAGE_CLASS_NAME=local-path (K3s default)"
    elif [[ -n "${default_sc:-}" ]]; then
      STORAGE_CLASS_NAME="$default_sc"
      log "Auto-selected STORAGE_CLASS_NAME=$STORAGE_CLASS_NAME (cluster default)"
    else
      set +e
      STORAGE_CLASS_NAME="$(kubectl --kubeconfig "$kubeconfig_file" get sc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
      set -e
      if [[ -n "${STORAGE_CLASS_NAME:-}" ]]; then
        log "Auto-selected STORAGE_CLASS_NAME=$STORAGE_CLASS_NAME (first available)"
      else
        log "WARNING: No storage classes discovered; the extension may fail to provision a PVC."
      fi
    fi

    if [[ "${STORAGE_CLASS_NAME:-}" == "longhorn" ]]; then
      log "WARNING: selected storage class is 'longhorn'. If Longhorn volumes are not ready, the Connected Registry pod will remain Pending."
      set +e
      longhorn_unready="$(kubectl --kubeconfig "$kubeconfig_file" -n longhorn-system get pods --no-headers 2>/dev/null | awk '$2!=$3 {print}' | head -n 3)"
      set -e
      if [[ -n "${longhorn_unready:-}" ]]; then
        log "WARNING: Detected non-ready Longhorn pods:"
        printf '%s\n' "$longhorn_unready" >&2
      fi
    fi
  fi
fi

# Optional: use local kubectl context for discovery if explicitly enabled.
has_kubectl="false"
if command -v kubectl >/dev/null 2>&1; then
  has_kubectl="true"
fi

if [[ "$USE_LOCAL_KUBECTL_DISCOVERY" == "true" && -z "$SERVICE_CLUSTER_IP" && "$has_kubectl" == "true" ]]; then
  set +e
  kube_svc_ip="$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  set -e
  if [[ -n "${kube_svc_ip:-}" ]]; then
    base_prefix="${kube_svc_ip%.*}"
    candidate_ip="${base_prefix}.250"
    SERVICE_CLUSTER_IP="$candidate_ip"
    log "(local) Auto-selected SERVICE_CLUSTER_IP=$SERVICE_CLUSTER_IP based on kubernetes service IP ($kube_svc_ip)"
  fi
fi

# Final fallback.
SERVICE_CLUSTER_IP="${SERVICE_CLUSTER_IP:-10.43.0.250}"

# If kubectl is available, try to discover a default storage class for K3s using local context (explicit opt-in).
if [[ "$USE_LOCAL_KUBECTL_DISCOVERY" == "true" && -z "$STORAGE_CLASS_NAME" && "$has_kubectl" == "true" ]]; then
  set +e
  STORAGE_CLASS_NAME="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n 1)"
  set -e
  if [[ -z "${STORAGE_CLASS_NAME:-}" ]]; then
    set +e
    kubectl get sc local-path >/dev/null 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      STORAGE_CLASS_NAME="local-path"
    fi
  fi
fi

log "Using:"
log "  RESOURCE_GROUP=$RESOURCE_GROUP"
log "  CLUSTER_NAME=$CLUSTER_NAME"
log "  ACR_NAME=$ACR_NAME"
log "  CONNECTED_REGISTRY_NAME=$CONNECTED_REGISTRY_NAME"
log "  EXTENSION_NAME=$EXTENSION_NAME"
log "  SERVICE_CLUSTER_IP=$SERVICE_CLUSTER_IP"
log "  STORAGE_CLASS_NAME=${STORAGE_CLASS_NAME:-<unset>}"

log "Generating protected settings for the Connected Registry extension"
protected_file="$(mktemp -t protected-settings-extension.XXXXXX.json)"

connection_string="$(az acr connected-registry get-settings \
  --name "$CONNECTED_REGISTRY_NAME" \
  --registry "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --parent-protocol https \
  --generate-password 1 \
  --query ACR_REGISTRY_CONNECTION_STRING \
  --output tsv \
  --yes | tr -d '\r\n')"

CONNECTION_STRING="$connection_string" PROTECTED_FILE="$protected_file" python3 - <<'PY'
import json
import os

connection_string = os.environ.get('CONNECTION_STRING', '')
protected_file = os.environ.get('PROTECTED_FILE', '')

with open(protected_file, 'w', encoding='utf-8') as f:
    json.dump({"connectionString": connection_string}, f)
    f.write("\n")
PY

log "Deploying Connected Registry Arc extension to cluster"
common_args=(
  --cluster-name "$CLUSTER_NAME"
  --cluster-type connectedClusters
  --name "$EXTENSION_NAME"
  --resource-group "$RESOURCE_GROUP"
  --config "service.clusterIP=$SERVICE_CLUSTER_IP"
  --config-protected-file "$protected_file"
)

if [[ -n "${STORAGE_CLASS_NAME:-}" ]]; then
  common_args+=(--config "pvc.storageClassName=$STORAGE_CLASS_NAME")
fi

# Create or update (create fails if already exists).
set +e
az k8s-extension show --name "$EXTENSION_NAME" --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --cluster-type connectedClusters >/dev/null 2>&1
exists=$?
set -e

if [[ $exists -eq 0 ]]; then
  log "Extension already exists; updating it"
  az k8s-extension update "${common_args[@]}" --yes >/dev/null
else
  az k8s-extension create \
    --extension-type Microsoft.ContainerRegistry.ConnectedRegistry \
    "${common_args[@]}" >/dev/null
fi

log "Waiting for extension provisioningState=Succeeded"
start_epoch=$(date +%s)
timeout_seconds=1200
while true; do
  state="$(az k8s-extension show --name "$EXTENSION_NAME" --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --cluster-type connectedClusters --query provisioningState -o tsv)"
  if [[ "$state" == "Succeeded" ]]; then
    break
  fi
  if [[ "$state" == "Failed" ]]; then
    log "Extension provisioning failed. Dumping details:"
    az k8s-extension show --name "$EXTENSION_NAME" --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --cluster-type connectedClusters -o jsonc || true
    die "Extension provisioningState=Failed"
  fi
  now_epoch=$(date +%s)
  if (( now_epoch - start_epoch > timeout_seconds )); then
    die "Timed out waiting for extension to provision"
  fi
  log "Current provisioningState=$state (waiting...)"
  sleep 15
done

log "Extension installed. Checking connected registry cloud resource state"
az acr connected-registry show -r "$ACR_NAME" -g "$RESOURCE_GROUP" -n "$CONNECTED_REGISTRY_NAME" -o table || true

if [[ "$VALIDATE_WITH_KUBECTL" == "true" ]] && command -v kubectl >/dev/null 2>&1; then
  log "Validating Kubernetes resources via Arc proxy"

  if [[ -z "${kubeconfig_file:-}" ]]; then
    start_arc_proxy "for validation"
  else
    log "Reusing existing Arc proxy for validation"
  fi

  log "Arc proxy ready; checking connected registry namespace/pods/service"
  kubectl --kubeconfig "$kubeconfig_file" get ns connected-registry
  kubectl --kubeconfig "$kubeconfig_file" get pods -n connected-registry -o wide
  kubectl --kubeconfig "$kubeconfig_file" get svc -n connected-registry -o wide
fi

log "Done"
