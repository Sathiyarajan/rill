#!/usr/bin/env bash
# Stops every component of the Rill lab: kills port-forwards, scales vLLM/TGI/
# KServe down to free the GPU, and tears down the monitoring stack. Idempotent
# — safe to re-run if things are already stopped.
#
# Does NOT delete the kind cluster or the model-cache PVC — that would lose
# the downloaded model weights and require re-downloading on next start. To
# fully tear down the cluster instead: `kind delete cluster --name genai-lab`.
set -uo pipefail

log() { echo -e "\n=== $* ===\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="genai"

cd "$SCRIPT_DIR"

# --- 1. Kill any port-forwards started by start-rill.sh or the other scripts ---
log "Stopping port-forwards"
for pidfile in /tmp/rill-vllm-api-portforward.pid /tmp/rill-vllm-metrics-portforward.pid \
               /tmp/genai-lab-vllm-portforward.pid; do
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    kill "$(cat "$pidfile")" 2>/dev/null && echo "Killed port-forward (pid $(cat "$pidfile"))"
  fi
  rm -f "$pidfile"
done
# Catch-all in case a port-forward was started outside a tracked pidfile
pkill -f "kubectl -n $NAMESPACE port-forward" 2>/dev/null && echo "Killed stray port-forward(s)" || true

# --- 2. Scale down every GPU-requesting workload (only one GPU exists) ---
log "Scaling down GPU workloads"
kubectl -n "$NAMESPACE" scale deployment/vllm --replicas=0 2>/dev/null || echo "vllm deployment not found, skipping"
kubectl -n "$NAMESPACE" scale deployment/tgi --replicas=0 2>/dev/null || echo "tgi deployment not found, skipping"
kubectl -n "$NAMESPACE" delete inferenceservice qwen-vllm --ignore-not-found

# --- 3. Tear down monitoring stack ---
log "Stopping monitoring stack"
if [ -f monitoring/docker-compose.yaml ]; then
  (cd monitoring && docker compose down)
fi

log "Stopped. Cluster and model-cache PVC left intact — run start-rill.sh to bring it back up quickly."
