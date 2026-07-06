#!/usr/bin/env bash
# Concurrent-request load test against vLLM to demonstrate continuous batching
# under load. Uses `hey` if available, else falls back to a Python asyncio
# script (written here, idempotent to re-run). Requires the port-forward from
# test-inference.sh, or starts its own.
set -euo pipefail

NAMESPACE="genai"
SERVICE="vllm"
LOCAL_PORT="8000"
CONCURRENCY="${CONCURRENCY:-10}"
REQUESTS="${REQUESTS:-50}"
PIDFILE="/tmp/genai-lab-vllm-portforward.pid"

# Reuse existing port-forward if test-inference.sh left one running, else start one.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Reusing existing port-forward (pid $(cat "$PIDFILE"))"
  OWN_PF=false
else
  echo "Starting port-forward svc/${SERVICE} ${LOCAL_PORT}:8000"
  kubectl -n "$NAMESPACE" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:8000" \
    >/tmp/genai-lab-portforward.log 2>&1 &
  PF_PID=$!
  echo "$PF_PID" > "$PIDFILE"
  OWN_PF=true
  for i in $(seq 1 20); do
    curl -s "http://localhost:${LOCAL_PORT}/health" >/dev/null 2>&1 && break
    sleep 1
  done
fi

cleanup() {
  if [ "$OWN_PF" = true ] && [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}
trap cleanup EXIT

PAYLOAD_FILE="/tmp/genai-lab-load-payload.json"
cat > "$PAYLOAD_FILE" <<'EOF'
{
  "model": "Qwen/Qwen2.5-3B-Instruct",
  "messages": [{"role": "user", "content": "Write a two-sentence summary of continuous batching in LLM serving."}],
  "max_tokens": 150,
  "temperature": 0.3
}
EOF

if command -v hey &>/dev/null; then
  echo "=== Running 'hey' load test: ${REQUESTS} requests, concurrency ${CONCURRENCY} ==="
  hey -n "$REQUESTS" -c "$CONCURRENCY" -m POST \
    -H "Content-Type: application/json" \
    -D "$PAYLOAD_FILE" \
    "http://localhost:${LOCAL_PORT}/v1/chat/completions"
else
  echo "'hey' not found, falling back to Python asyncio load test."
  echo "(Install hey for a nicer report: https://github.com/rakyll/hey)"

  SCRIPT_FILE="/tmp/genai-lab-load-test.py"
  cat > "$SCRIPT_FILE" <<'PYEOF'
import asyncio, json, os, time, sys
import urllib.request

CONCURRENCY = int(os.environ.get("CONCURRENCY", "10"))
REQUESTS = int(os.environ.get("REQUESTS", "50"))
URL = f"http://localhost:{os.environ.get('LOCAL_PORT', '8000')}/v1/chat/completions"
PAYLOAD = json.dumps({
    "model": "Qwen/Qwen2.5-3B-Instruct",
    "messages": [{"role": "user", "content": "Write a two-sentence summary of continuous batching in LLM serving."}],
    "max_tokens": 150,
    "temperature": 0.3,
}).encode()

def one_request():
    start = time.time()
    req = urllib.request.Request(URL, data=PAYLOAD, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as resp:
        resp.read()
    return time.time() - start

async def worker(sem, latencies):
    async with sem:
        loop = asyncio.get_event_loop()
        latency = await loop.run_in_executor(None, one_request)
        latencies.append(latency)

async def main():
    sem = asyncio.Semaphore(CONCURRENCY)
    latencies = []
    start = time.time()
    await asyncio.gather(*[worker(sem, latencies) for _ in range(REQUESTS)])
    total = time.time() - start
    latencies.sort()
    print(f"\nTotal requests: {REQUESTS}, concurrency: {CONCURRENCY}")
    print(f"Total time: {total:.2f}s, throughput: {REQUESTS/total:.2f} req/s")
    print(f"Latency p50: {latencies[len(latencies)//2]:.2f}s  p95: {latencies[int(len(latencies)*0.95)]:.2f}s  max: {latencies[-1]:.2f}s")

asyncio.run(main())
PYEOF
  CONCURRENCY="$CONCURRENCY" REQUESTS="$REQUESTS" LOCAL_PORT="$LOCAL_PORT" python3 "$SCRIPT_FILE"
fi
