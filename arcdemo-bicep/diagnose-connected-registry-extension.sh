#!/usr/bin/env bash
set -euo pipefail

# Diagnose why the Connected Registry Arc extension is failing on an Arc-enabled Kubernetes cluster.
# Runs Azure-side checks (ARM resource lookup) and (optionally) cluster-side checks via ONE `az connectedk8s proxy`.
#
# Usage:
#   bash arcdemo-bicep/diagnose-connected-registry-extension.sh
#
# Optional env overrides:
#   RESOURCE_GROUP=arc-devops-demo
#   CLUSTER_NAME=ArcDev-K3s-Data-3ff7
#   EXTENSION_NAME=ctecharcdemoConnectedRegistry
#   RUN_KUBECTL=true|false
#   PROXY_READY_TIMEOUT_SECONDS=180
#   DEBUG=true|false

RESOURCE_GROUP_DEFAULT="arc-devops-demo"
CLUSTER_NAME_DEFAULT="ArcDev-K3s-Data-3ff7"
RUN_KUBECTL_DEFAULT="true"
PROXY_READY_TIMEOUT_SECONDS_DEFAULT="180"
DEBUG_DEFAULT="false"

RESOURCE_GROUP="${RESOURCE_GROUP:-$RESOURCE_GROUP_DEFAULT}"
CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME_DEFAULT}"
EXTENSION_NAME="${EXTENSION_NAME:-}" # optional; if unset we attempt to discover
RUN_KUBECTL="${RUN_KUBECTL:-$RUN_KUBECTL_DEFAULT}"
PROXY_READY_TIMEOUT_SECONDS="${PROXY_READY_TIMEOUT_SECONDS:-$PROXY_READY_TIMEOUT_SECONDS_DEFAULT}"
DEBUG="${DEBUG:-$DEBUG_DEFAULT}"

log() { printf '%s\n' "[$(date -Is)] $*"; }
die() { printf '%s\n' "ERROR: $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

require_cmd az

if [[ "$RUN_KUBECTL" == "true" ]]; then
  require_cmd kubectl
  require_cmd python3
fi

az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
az config set extension.dynamic_install_allow_preview=true >/dev/null

log "Context"
log "  RESOURCE_GROUP=$RESOURCE_GROUP"
log "  CLUSTER_NAME=$CLUSTER_NAME"
log "  EXTENSION_NAME=${EXTENSION_NAME:-<auto-discover>}"
log "  RUN_KUBECTL=$RUN_KUBECTL"

log "Azure account"
az account show --query '{name:name, user:user.name, tenantId:tenantId, subscriptionId:id}' -o jsonc || true

sub_id="$(az account show --query id -o tsv)"
cluster_id="/subscriptions/$sub_id/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Kubernetes/connectedClusters/$CLUSTER_NAME"

log "Connected cluster ARM resource"
# This call has been reliable even when other RP calls hang.
az resource show --ids "$cluster_id" -o jsonc || die "Failed to read connected cluster ARM resource"

# --- Extension discovery ---
# The extension resource is typically a child resource of the connected cluster:
#   .../connectedClusters/<cluster>/providers/Microsoft.KubernetesConfiguration/extensions/<extensionName>

ext_id=""

if [[ -n "$EXTENSION_NAME" ]]; then
  ext_id="$cluster_id/providers/Microsoft.KubernetesConfiguration/extensions/$EXTENSION_NAME"
fi

try_show_extension_by_id() {
  local id="$1"
  if [[ -z "$id" ]]; then
    return 1
  fi
  log "Extension ARM resource (by id): $id"
  if ! az resource show --ids "$id" -o jsonc; then
    return 1
  fi
  return 0
}

try_list_extensions_in_rg() {
  # List ALL resources under the RG, then filter client-side with grep.
  # (Some environments don’t return child resources from az resource list with resource-type filters.)
  log "Searching resource group for extension resources (client-side filter)"
  az resource list -g "$RESOURCE_GROUP" -o tsv --query "[].id" | grep -F "/providers/Microsoft.KubernetesConfiguration/extensions/" | grep -F "/connectedClusters/$CLUSTER_NAME/" || true
}

if [[ -n "$ext_id" ]]; then
  if ! try_show_extension_by_id "$ext_id"; then
    log "Extension not found at expected id; will try discovery"
    ext_id=""
  fi
fi

if [[ -z "$ext_id" ]]; then
  matches="$(try_list_extensions_in_rg)"
  if [[ -n "$matches" ]]; then
    # Prefer connected registry extension if it’s present.
    ext_id="$(printf '%s\n' "$matches" | grep -E 'ConnectedRegistry|connectedregistry|connectedRegistry' | head -n 1 || true)"
    if [[ -z "$ext_id" ]]; then
      ext_id="$(printf '%s\n' "$matches" | head -n 1)"
    fi
  fi

  if [[ -n "$ext_id" ]]; then
    log "Discovered extension id: $ext_id"
    az resource show --ids "$ext_id" -o jsonc || true
  else
    log "No extension ARM resources discovered in RG '$RESOURCE_GROUP' for cluster '$CLUSTER_NAME'."
    log "If Azure Portal shows an extension failure, it may be in a different resource group/subscription, or the RP call is failing."
  fi
fi

# --- Cluster-side checks via ONE proxy ---
if [[ "$RUN_KUBECTL" != "true" ]]; then
  log "RUN_KUBECTL=false; skipping cluster-side proxy inspection"
  exit 0
fi

log "Cluster-side diagnostics via az connectedk8s proxy"

kubeconfig_file="$(mktemp -t kubeconfig.arcproxy.${CLUSTER_NAME}.XXXXXX.yaml)"
proxy_log="$(mktemp -t connectedk8s-proxy.${CLUSTER_NAME}.XXXXXX.log)"

cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  if [[ -n "${proxy_pid:-}" ]] && kill -0 "$proxy_pid" >/dev/null 2>&1; then
    kill "$proxy_pid" >/dev/null 2>&1 || true
    wait "$proxy_pid" >/dev/null 2>&1 || true
  fi
  rm -f "$kubeconfig_file" "$proxy_log" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

# Best-effort stop any other proxies to avoid port conflicts.
# (This is intentionally broad; if you’re running another proxy intentionally, set RUN_KUBECTL=false.)
pkill -f 'az connectedk8s proxy' >/dev/null 2>&1 || true
sleep 1

proxy_port="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()
PY
)"

proxy_args=(
  connectedk8s proxy
  --name "$CLUSTER_NAME"
  --resource-group "$RESOURCE_GROUP"
  --port "$proxy_port"
  --file "$kubeconfig_file"
  --kube-context "$CLUSTER_NAME"
)

if [[ "$DEBUG" == "true" ]]; then
  proxy_args+=(--debug)
fi

log "Starting proxy (port=$proxy_port)"
az "${proxy_args[@]}" >"$proxy_log" 2>&1 &
proxy_pid=$!

start_epoch="$(date +%s)"
while true; do
  if ! kill -0 "$proxy_pid" >/dev/null 2>&1; then
    log "Proxy process exited unexpectedly. proxy_log (head):"
    sed -n '1,200p' "$proxy_log" >&2 || true
    die "az connectedk8s proxy failed"
  fi

  if [[ -s "$kubeconfig_file" ]]; then
    if kubectl --kubeconfig "$kubeconfig_file" --request-timeout=5s get --raw=/version >/dev/null 2>&1; then
      break
    fi
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - start_epoch > PROXY_READY_TIMEOUT_SECONDS )); then
    log "Timed out waiting for proxy readiness. kubeconfig bytes=$(stat -c%s "$kubeconfig_file" 2>/dev/null || echo 0)"
    log "proxy_log (head):"
    sed -n '1,220p' "$proxy_log" >&2 || true
    die "Timed out waiting for Arc proxy"
  fi

  sleep 2
done

log "Proxy ready; collecting namespace/pod status"

namespaces=(azure-arc azure-extensions connected-registry)
for ns in "${namespaces[@]}"; do
  echo ""
  log "Namespace: $ns"
  kubectl --kubeconfig "$kubeconfig_file" get ns "$ns" >/dev/null 2>&1 || { log "  (missing)"; continue; }

  log "Pods in $ns"
  kubectl --kubeconfig "$kubeconfig_file" -n "$ns" get pods -o wide || true

  log "Recent events in $ns (tail 30)"
  kubectl --kubeconfig "$kubeconfig_file" -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 30 || true

done

if kubectl --kubeconfig "$kubeconfig_file" get ns connected-registry >/dev/null 2>&1; then
  echo ""
  log "connected-registry services/endpoints"
  kubectl --kubeconfig "$kubeconfig_file" -n connected-registry get svc -o wide || true
  kubectl --kubeconfig "$kubeconfig_file" -n connected-registry get endpoints -o wide || true
fi

# Describe/log the first non-running pod in likely namespaces
for ns in azure-extensions connected-registry; do
  bad_pod="$(kubectl --kubeconfig "$kubeconfig_file" -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Running" {print $1; exit}')"
  if [[ -n "${bad_pod:-}" ]]; then
    echo ""
    log "Describe failing pod: $ns/$bad_pod"
    kubectl --kubeconfig "$kubeconfig_file" -n "$ns" describe pod "$bad_pod" | sed -n '1,260p' || true

    log "Logs (tail 200): $ns/$bad_pod"
    kubectl --kubeconfig "$kubeconfig_file" -n "$ns" logs "$bad_pod" --tail=200 2>&1 || true
  fi
done

log "Done"
