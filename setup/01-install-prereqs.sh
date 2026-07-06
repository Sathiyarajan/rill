#!/usr/bin/env bash
# Installs Docker CLI + NVIDIA Container Toolkit + kind + kubectl + Helm inside WSL2 Ubuntu.
# Idempotent: every step checks for existing install before acting.
#
# Assumes: Docker Desktop for Windows is installed with WSL2 integration ON for this
# distro (so `docker` already works here), and the Windows NVIDIA driver has WSL2 GPU
# support installed. This script does NOT install a GPU driver inside WSL — WSL2 uses
# the Windows host driver via /usr/lib/wsl/lib.

set -euo pipefail

log() { echo -e "\n=== $* ===\n"; }

# --- 0. sanity: docker CLI reachable (from Docker Desktop WSL integration) ---
if ! command -v docker &>/dev/null; then
  echo "ERROR: 'docker' not found. Enable WSL2 integration for this distro in"
  echo "Docker Desktop > Settings > Resources > WSL Integration, then re-open this shell."
  exit 1
fi
log "Docker CLI found: $(docker --version)"

# --- 1. NVIDIA Container Toolkit (lets docker use --gpus all) ---
if ! dpkg -l | grep -q nvidia-container-toolkit; then
  log "Installing NVIDIA Container Toolkit"
  distribution="ubuntu$(. /etc/os-release; echo "$VERSION_ID" | tr -d '.')"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt-get update -y
  sudo apt-get install -y nvidia-container-toolkit
else
  log "NVIDIA Container Toolkit already installed, skipping"
fi

# Configure the docker runtime (Docker Desktop's dockerd, reached via WSL integration).
# Safe to re-run: nvidia-ctk merges config idempotently.
log "Configuring docker runtime for NVIDIA"
sudo nvidia-ctk runtime configure --runtime=docker || true
echo "NOTE: If this is the first time, restart Docker Desktop from the Windows tray"
echo "      (Quit and reopen) so it picks up the new runtime config."

# --- 2. kind ---
if ! command -v kind &>/dev/null; then
  log "Installing kind"
  curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
  chmod +x /tmp/kind
  sudo mv /tmp/kind /usr/local/bin/kind
else
  log "kind already installed: $(kind version)"
fi

# --- 3. kubectl ---
if ! command -v kubectl &>/dev/null; then
  log "Installing kubectl"
  KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -Lo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
else
  log "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# --- 4. Helm ---
if ! command -v helm &>/dev/null; then
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  log "Helm already installed: $(helm version --short)"
fi

# --- 5. Verify GPU visibility ---
log "Verifying GPU visibility (host driver via WSL2)"
if command -v nvidia-smi &>/dev/null; then
  nvidia-smi || echo "WARNING: nvidia-smi present but failed to run — check Windows NVIDIA driver."
else
  echo "WARNING: nvidia-smi not found in WSL PATH. It should exist at /usr/lib/wsl/lib/nvidia-smi."
  echo "         Verify the Windows NVIDIA driver has WSL2 GPU support installed."
fi

log "Verifying docker --gpus all"
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi \
  || echo "WARNING: 'docker run --gpus all' failed. Restart Docker Desktop and retry."

log "Done. If any WARNING above, resolve before continuing to setup/02-create-cluster.sh"
