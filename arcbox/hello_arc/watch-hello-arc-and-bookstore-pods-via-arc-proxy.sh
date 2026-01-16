#!/usr/bin/env bash
set -euo pipefail

# Watches pod status in multiple namespaces via `az connectedk8s proxy`.
# Useful for observing GitOps reconciliation rollouts.

CLUSTER_NAME_DEFAULT="ArcDev-K3s-Data-3ff7"
RESOURCE_GROUP_DEFAULT="arc-devops-demo"

CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER_NAME_DEFAULT}"
RESOURCE_GROUP="${RESOURCE_GROUP:-$RESOURCE_GROUP_DEFAULT}"

NAMESPACE_1="${NAMESPACE_1:-hello-arc}"
NAMESPACE_2="${NAMESPACE_2:-bookstore}"

REFRESH_SECONDS="${REFRESH_SECONDS:-2}"
SHOW_EVENTS="${SHOW_EVENTS:-false}"
EVENTS_TAIL="${EVENTS_TAIL:-15}"

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
require_cmd kubectl
require_cmd python3

az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
az config set extension.dynamic_install_allow_preview=true >/dev/null

log "Ensuring Azure CLI connectedk8s extension is installed"
az extension add --name connectedk8s >/dev/null

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

kubeconfig_file="$(mktemp -t kubeconfig.arcproxy.watch.XXXXXX.yaml)"
proxy_log="$(mktemp -t connectedk8s-proxy.watch.XXXXXX.log)"

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

log "Proxy ready. Watching pods in namespaces: $NAMESPACE_1, $NAMESPACE_2"
log "Press Ctrl+C to stop."

is_tty=false
if [[ -t 1 ]]; then
  is_tty=true
fi

pods_json_1="$(mktemp -t pods.${NAMESPACE_1}.XXXXXX.json)"
pods_json_2="$(mktemp -t pods.${NAMESPACE_2}.XXXXXX.json)"

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
  [[ -n "${pods_json_1:-}" ]] && rm -f "$pods_json_1" >/dev/null 2>&1 || true
  [[ -n "${pods_json_2:-}" ]] && rm -f "$pods_json_2" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

render_table() {
  local now
  now="$(date -Is)"
  python3 - "$NAMESPACE_1" "$pods_json_1" "$NAMESPACE_2" "$pods_json_2" "$now" <<'PY'
import datetime as dt
import json
import sys

def parse_age(iso: str) -> str:
    try:
        # Kubernetes timestamps are RFC3339, e.g. 2026-01-15T18:48:45Z
        if iso.endswith('Z'):
            created = dt.datetime.fromisoformat(iso.replace('Z', '+00:00'))
        else:
            created = dt.datetime.fromisoformat(iso)
        delta = dt.datetime.now(dt.timezone.utc) - created.astimezone(dt.timezone.utc)
        seconds = int(delta.total_seconds())
        if seconds < 60:
            return f"{seconds}s"
        minutes = seconds // 60
        if minutes < 60:
            return f"{minutes}m"
        hours = minutes // 60
        if hours < 48:
            return f"{hours}h"
        days = hours // 24
        return f"{days}d"
    except Exception:
        return iso

def summarize_pod(pod: dict) -> dict:
    meta = pod.get('metadata', {})
    status = pod.get('status', {})
    spec = pod.get('spec', {})

    name = meta.get('name', '')
    phase = status.get('phase', '')
    pod_ip = status.get('podIP', '')
    node = spec.get('nodeName', '')
    created = meta.get('creationTimestamp', '')
    age = parse_age(created) if created else ''

    cs = status.get('containerStatuses') or []
    ready_count = sum(1 for c in cs if c.get('ready'))
    total_count = len(cs)
    restarts = sum(int(c.get('restartCount') or 0) for c in cs)
    ready = f"{ready_count}/{total_count}" if total_count else "0/0"

    # Improve status readability for common waiting reasons
    pretty_status = phase
    for c in cs:
        st = c.get('state') or {}
        if 'waiting' in st and st['waiting'].get('reason'):
            pretty_status = st['waiting']['reason']
            break
        if 'terminated' in st and st['terminated'].get('reason'):
            pretty_status = st['terminated']['reason']
            break

    return {
        'pod': name,
        'ready': ready,
        'status': pretty_status,
        'restarts': str(restarts),
        'age': age,
        'ip': pod_ip,
        'node': node,
    }

def load_rows(ns: str, path: str):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        return []

    items = data.get('items') or []
    rows = []
    for pod in items:
        row = summarize_pod(pod)
        row['namespace'] = ns
        rows.append(row)
    rows.sort(key=lambda r: (r['namespace'], r['pod']))
    return rows

ns1, p1, ns2, p2, now = sys.argv[1:6]

rows = load_rows(ns1, p1) + load_rows(ns2, p2)

print(f"Last update: {now}")
print(f"Namespaces: {ns1}, {ns2}")
print("")

headers = ['NAMESPACE', 'POD', 'READY', 'STATUS', 'RESTARTS', 'AGE', 'IP', 'NODE']
table = [headers]
for r in rows:
    table.append([
        r.get('namespace', ''),
        r.get('pod', ''),
        r.get('ready', ''),
        r.get('status', ''),
        r.get('restarts', ''),
        r.get('age', ''),
        r.get('ip', ''),
        r.get('node', ''),
    ])

widths = [max(len(str(row[i])) for row in table) if table else 0 for i in range(len(headers))]

def fmt(row):
    return "  ".join(str(row[i]).ljust(widths[i]) for i in range(len(headers)))

for idx, row in enumerate(table):
    print(fmt(row))
    if idx == 0:
        print("  ".join('-' * w for w in widths))

if not rows:
    print("(no pods found yet)")
PY
}

last_lines_printed=0

while true; do
  set +e
  kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE_1" get pods -o json >"$pods_json_1" 2>/dev/null
  kubectl --kubeconfig "$kubeconfig_file" -n "$NAMESPACE_2" get pods -o json >"$pods_json_2" 2>/dev/null
  set -e

  output="$(render_table)"

  if [[ "$is_tty" == "true" ]]; then
    # Move cursor up to the start of the previous render and clear only the previously-rendered area.
    if [[ $last_lines_printed -gt 0 ]]; then
      printf '\033[%sA' "$last_lines_printed"  # cursor up N lines
      printf '\033[J'                     # clear to end of screen
    fi
  fi

  printf '%s\n' "$output"
  last_lines_printed=$(printf '%s\n' "$output" | wc -l | tr -d ' ')

  if [[ "$SHOW_EVENTS" == "true" ]]; then
    printf '\n'
    for ns in "$NAMESPACE_1" "$NAMESPACE_2"; do
      printf '%s\n' "Recent events in $ns (tail $EVENTS_TAIL):"
      kubectl --kubeconfig "$kubeconfig_file" -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n "$EVENTS_TAIL" || true
      printf '\n'
    done
    # Events add extra lines below the table; include them in line count so refresh overwrites cleanly.
    if [[ "$is_tty" == "true" ]]; then
      extra_lines=$(( (EVENTS_TAIL + 3) * 2 + 2 ))
      last_lines_printed=$(( last_lines_printed + extra_lines ))
    fi
  fi

  sleep "$REFRESH_SECONDS"
done
