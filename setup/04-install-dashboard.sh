#!/usr/bin/env bash
# Installs the official Kubernetes Dashboard (web UI for browsing pods,
# deployments, logs, events) and an admin ServiceAccount to log into it.
# Idempotent: kubectl apply is a no-op on unchanged resources.
set -euo pipefail

log() { echo -e "\n=== $* ===\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DASHBOARD_VERSION="v2.7.0"

log "Installing Kubernetes Dashboard ${DASHBOARD_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

log "Applying admin ServiceAccount for login"
kubectl apply -f "$REPO_ROOT/manifests/dashboard-admin.yaml"

log "Waiting for dashboard deployment"
kubectl -n kubernetes-dashboard rollout status deployment/kubernetes-dashboard --timeout=180s

log "Login token (valid 24h) — copy this into the dashboard's Token login screen"
kubectl -n kubernetes-dashboard create token dashboard-admin --duration=24h
echo

log "Done. Next: kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443"
echo "Then open https://localhost:8443 in your browser (accept the self-signed cert warning)."
