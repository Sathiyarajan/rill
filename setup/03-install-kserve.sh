#!/usr/bin/env bash
# Installs a lightweight KServe quickstart stack suited for kind: cert-manager +
# KServe CRDs/controller in RawDeployment mode (no Knative/Istio — those add
# real weight and complexity this single-node lab doesn't need). Idempotent.
set -euo pipefail

log() { echo -e "\n=== $* ===\n"; }

KSERVE_VERSION="v0.14.0"
CERT_MANAGER_VERSION="v1.15.3"

# --- 1. cert-manager (required by KServe's webhook certs) ---
if kubectl get ns cert-manager &>/dev/null; then
  log "cert-manager namespace already exists, skipping install"
else
  log "Installing cert-manager ${CERT_MANAGER_VERSION}"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kubectl -n cert-manager rollout status deployment/cert-manager --timeout=180s
  kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
fi

# --- 2. KServe CRDs + controller, RawDeployment mode (no Knative) ---
if kubectl get ns kserve &>/dev/null; then
  log "kserve namespace already exists, skipping install"
else
  log "Installing KServe ${KSERVE_VERSION} (RawDeployment mode)"
  # KServe's InferenceService CRD is large enough that a normal `kubectl apply`
  # fails with "metadata.annotations: Too long: must have at most 262144 bytes"
  # (it stores the whole manifest in the kubectl.kubernetes.io/last-applied-configuration
  # annotation). --server-side apply doesn't use that annotation, avoiding the limit.
  kubectl apply --server-side --force-conflicts -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml"
  kubectl -n kserve rollout status deployment/kserve-controller-manager --timeout=180s

  # Force RawDeployment as the default deploy mode cluster-wide (skip Knative dependency)
  kubectl patch configmap/inferenceservice-config -n kserve --type=merge -p \
    '{"data":{"deploy":"{\"defaultDeploymentMode\": \"RawDeployment\"}"}}'
fi

log "KServe installed. Deploy manifests/kserve-inferenceservice.yaml next."
