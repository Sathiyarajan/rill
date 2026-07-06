#!/usr/bin/env bash
# Creates the kind cluster with GPU passthrough and installs the NVIDIA device
# plugin so pods can request nvidia.com/gpu. Idempotent.
set -euo pipefail

log() { echo -e "\n=== $* ===\n"; }

CLUSTER_NAME="genai-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# --- 1. Make docker's default runtime nvidia so the kind node container itself
#         gets GPU access (kind has no --gpus flag; this is the standard workaround
#         documented by the kind + NVIDIA community). ---
log "Checking Docker Desktop default-runtime=nvidia"
if ! docker info 2>/dev/null | grep -qi "Default Runtime: nvidia"; then
  echo "Docker default runtime is not 'nvidia'."
  echo "Open Docker Desktop > Settings > Docker Engine, and merge this into the JSON:"
  cat <<'EOF'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF
  echo "Then Apply & Restart, and re-run this script."
  echo "(This step is one-time manual config; Docker Desktop doesn't expose it via CLI.)"
  read -rp "Press Enter once default-runtime=nvidia is set and Docker Desktop restarted..." _
fi

# --- 2. Build a custom kind node image with:
#         (a) NVIDIA_VISIBLE_DEVICES baked in via ENV, so Docker Desktop's nvidia
#             runtime actually injects the GPU into the node container itself
#             (default-runtime=nvidia alone does not do this without --gpus, which
#             kind's node-creation path can't pass).
#         (b) nvidia-container-toolkit installed *inside* the node image, so the
#             containerd running inside the node (which is what actually launches
#             pods, including the device plugin) has nvidia-container-runtime
#             available at /usr/bin/nvidia-container-runtime — registered as an
#             additional (non-default) containerd runtime via containerdConfigPatches
#             in kind-config.yaml, selected per-pod via the "nvidia" RuntimeClass
#             created below. Without this, pods never get GPU access even though
#             `docker exec <node> nvidia-smi` works fine.
#         Idempotent: docker build layer-caches. ---
GPU_NODE_IMAGE="kindest/node:v1.30.0-gpu"
log "Building GPU-enabled kind node image ($GPU_NODE_IMAGE)"
docker build -t "$GPU_NODE_IMAGE" -f - "$SCRIPT_DIR" <<'EOF'
FROM kindest/node:v1.30.0
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all
RUN apt-get update -y && apt-get install -y curl gnupg && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    && apt-get update -y \
    && apt-get install -y nvidia-container-toolkit \
    && rm -rf /var/lib/apt/lists/*
EOF

# --- 3. Create the kind cluster (idempotent: skip if it already exists) ---
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, skipping create"
else
  log "Creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --config "$REPO_ROOT/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# --- 3b. Create the "nvidia" RuntimeClass so only pods that opt in (via
#          spec.runtimeClassName: nvidia) get routed through the nvidia containerd
#          runtime registered in kind-config.yaml — idempotent (apply is a no-op
#          if unchanged). ---
log "Applying nvidia RuntimeClass"
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

# --- 4. Verify GPU is visible inside the kind node container ---
log "Verifying GPU visible inside kind node"
docker exec "${CLUSTER_NAME}-control-plane" nvidia-smi \
  || { echo "ERROR: GPU not visible inside kind node. Check default-runtime=nvidia and restart Docker Desktop."; exit 1; }

# --- 5. Install NVIDIA device plugin via Helm (idempotent: helm upgrade --install).
#         The chart's default daemonset affinity requires Node Feature Discovery
#         labels (feature.node.kubernetes.io/pci-10de.present=true, etc) that we
#         don't run NFD to produce. We label the node with the one alternative
#         match (nvidia.com/gpu.present=true) NFD would normally set, and disable
#         the chart's built-in affinity so it schedules purely on that label. ---
log "Labeling node for device plugin scheduling (no NFD in this lab)"
kubectl label node "${CLUSTER_NAME}-control-plane" nvidia.com/gpu.present=true --overwrite

log "Installing/upgrading NVIDIA device plugin"
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update
helm repo update nvdp
helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --version 0.16.2 \
  --set gfd.enabled=false \
  --set migStrategy=none \
  --set runtimeClassName=nvidia \
  --set-json 'affinity={}'

log "Waiting for device plugin daemonset to be ready"
kubectl -n kube-system rollout status daemonset/nvidia-device-plugin --timeout=120s

log "Verifying node advertises nvidia.com/gpu"
# Node status takes a few seconds to reflect the device plugin's capacity update
# after the daemonset reports ready, so poll briefly instead of checking once.
for i in $(seq 1 15); do
  GPU_CAPACITY=$(kubectl get node "${CLUSTER_NAME}-control-plane" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  [ -n "$GPU_CAPACITY" ] && break
  sleep 2
done
echo "${CLUSTER_NAME}-control-plane: nvidia.com/gpu = ${GPU_CAPACITY:-<none>}"
if [ -z "$GPU_CAPACITY" ]; then
  echo "ERROR: node never advertised nvidia.com/gpu. Check: kubectl -n kube-system logs -l app.kubernetes.io/instance=nvidia-device-plugin"
  exit 1
fi

# --- 6. Create the app namespace ---
kubectl create namespace genai --dry-run=client -o yaml | kubectl apply -f -

log "Cluster ready. Node should show nvidia.com/gpu: 1 above."
