#!/usr/bin/env bash
# Install Argo CD and hand the cluster over to Git: after this, every add-on and app in this repo is
# installed and kept in sync by Argo CD (gitops/root-app.yaml). Use platform/install.sh instead only
# for a cluster that is not managed by Argo CD.
# Usage: ./gitops/bootstrap.sh [--dry-run]
set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

ARGOCD_CHART_VERSION=10.11.7

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo >/dev/null

if $DRY_RUN; then
  helm template argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" -n argocd \
    -f platform/argo-cd/values.yaml
  cat gitops/root-app.yaml
  exit 0
fi

helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  -n argocd --create-namespace -f platform/argo-cd/values.yaml --wait --timeout 10m

# From here Argo CD owns everything, including its own upgrades (gitops/apps/argo-cd.yaml).
kubectl apply -f gitops/root-app.yaml

echo "Argo CD is syncing. Initial admin password (rotate it, then delete the secret):"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
