#!/usr/bin/env bash
# Port-forwards the vLLM service and sends a test OpenAI-compatible chat
# completion request, pretty-printed with jq. Idempotent: kills any leftover
# port-forward on the same port before starting a fresh one.
set -euo pipefail

NAMESPACE="genai"
SERVICE="vllm"
LOCAL_PORT="8000"
REMOTE_PORT="8000"
PIDFILE="/tmp/genai-lab-vllm-portforward.pid"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install it: sudo apt-get install -y jq"
  exit 1
fi

# Clean up any previous port-forward from a prior run of this script
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi

echo "=== Port-forwarding svc/${SERVICE} ${LOCAL_PORT}:${REMOTE_PORT} ==="
kubectl -n "$NAMESPACE" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}" \
  >/tmp/genai-lab-portforward.log 2>&1 &
PF_PID=$!
echo "$PF_PID" > "$PIDFILE"

cleanup() {
  kill "$PF_PID" 2>/dev/null || true
  rm -f "$PIDFILE"
}
trap cleanup EXIT

# Wait for the port-forward to be ready
for i in $(seq 1 20); do
  if curl -s "http://localhost:${LOCAL_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "=== Sending test chat completion ==="
curl -s "http://localhost:${LOCAL_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-3B-Instruct",
    "messages": [{"role": "user", "content": "In one sentence, what is Kubernetes?"}],
    "max_tokens": 100,
    "temperature": 0.2
  }' | jq .

echo "=== Done ==="
