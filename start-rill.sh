#!/usr/bin/env bash
# Starts every component of the Rill lab: kind cluster (creates if missing),
# model weights PVC/download, vLLM serving, a persistent port-forward, and the
# Prometheus + Grafana monitoring stack. Idempotent — safe to re-run any time;
# each step skips or no-ops if already done.
#
# Does NOT start TGI or KServe by default — this laptop has exactly one GPU,
# and vLLM is the primary demo. See README.md for how to run those instead
# (they require scaling vLLM to 0 first).
set -euo pipefail

log() { echo -e "\n=== $* ===\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="genai"
CLUSTER_NAME="genai-lab"
PF_API_PIDFILE="/tmp/rill-vllm-api-portforward.pid"
PF_METRICS_PIDFILE="/tmp/rill-vllm-metrics-portforward.pid"

cd "$SCRIPT_DIR"

# --- 1. kind cluster + GPU passthrough + device plugin (idempotent) ---
log "Ensuring kind cluster is up"
bash setup/02-create-cluster.sh

# --- 2. Model weights PVC + download job ---
log "Ensuring model weights are downloaded"
kubectl apply -f manifests/pvc-model-cache.yaml
kubectl -n "$NAMESPACE" wait --for=condition=complete job/model-download --timeout=900s \
  || echo "NOTE: model-download job not complete/found — check 'kubectl -n $NAMESPACE logs job/model-download' if vLLM fails to start"

# --- 3. vLLM deployment, scaled up ---
log "Deploying vLLM and scaling to 1 replica"
kubectl apply -f manifests/vllm-deployment.yaml
kubectl -n "$NAMESPACE" scale deployment/vllm --replicas=1
kubectl -n "$NAMESPACE" rollout status deployment/vllm --timeout=600s

# --- 4. Persistent port-forwards (API on 8000, reused by metrics scrape too) ---
start_portforward() {
  local pidfile="$1" svc="$2" ports="$3"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "Port-forward for $svc already running (pid $(cat "$pidfile"))"
  else
    kubectl -n "$NAMESPACE" port-forward --address 0.0.0.0 "svc/$svc" "$ports" \
      >/tmp/rill-portforward-"$svc".log 2>&1 &
    echo $! > "$pidfile"
    disown
    echo "Started port-forward for $svc (pid $(cat "$pidfile"))"
  fi
}
log "Starting port-forward: svc/vllm 8000:8000"
start_portforward "$PF_API_PIDFILE" vllm "8000:8000"

# --- 5. Monitoring stack (Prometheus + Grafana) ---
log "Starting monitoring stack"
(cd monitoring && docker compose up -d)

# --- 6. Summary ---
sleep 3
log "Status"
kubectl -n "$NAMESPACE" get pods
echo
echo "vLLM API:        http://localhost:8000/v1/chat/completions"
echo "Prometheus:      http://localhost:9090"
echo "Grafana:         http://localhost:3000  (admin/admin, or anonymous viewer)"
echo
echo "Test it: bash scripts/test-inference.sh"
echo "Stop everything: bash stop-rill.sh"
