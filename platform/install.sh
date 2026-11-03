#!/usr/bin/env bash
# Install or upgrade the platform add-ons in dependency order, with pinned chart versions.
# Usage: ./platform/install.sh [--dry-run]
set -euo pipefail

cd "$(dirname "$0")"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

: "${CLUSTER_NAME:?set CLUSTER_NAME}"
: "${AWS_REGION:?set AWS_REGION}"
: "${VPC_ID:?set VPC_ID}"
: "${LBC_ROLE_ARN:?set LBC_ROLE_ARN (IRSA role for the load balancer controller)}"
: "${ESO_ROLE_ARN:?set ESO_ROLE_ARN (IRSA role for external-secrets)}"

LBC_CHART_VERSION=1.8.1
METRICS_SERVER_CHART_VERSION=3.12.1
ESO_CHART_VERSION=0.10.7

# install <release> <namespace> <chart> <version> <values-file> [extra helm args...]
install() {
  local release=$1 namespace=$2 chart=$3 version=$4 values=$5
  shift 5
  if $DRY_RUN; then
    helm template "$release" "$chart" --version "$version" -n "$namespace" -f "$values" "$@"
  else
    helm upgrade --install "$release" "$chart" --version "$version" \
      -n "$namespace" --create-namespace -f "$values" "$@" \
      --wait --timeout 5m
  fi
}

# apply_manifest <file>: the store's region comes from AWS_REGION, not from the file.
apply_manifest() {
  if $DRY_RUN; then
    sed "s/region: us-east-1/region: ${AWS_REGION}/" "$1"
  else
    sed "s/region: us-east-1/region: ${AWS_REGION}/" "$1" | kubectl apply -f -
  fi
}

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update >/dev/null
helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
helm repo update >/dev/null

install metrics-server kube-system metrics-server/metrics-server \
  "$METRICS_SERVER_CHART_VERSION" metrics-server/values.yaml

install aws-load-balancer-controller kube-system eks/aws-load-balancer-controller \
  "$LBC_CHART_VERSION" aws-load-balancer-controller/values.yaml \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$LBC_ROLE_ARN"

install external-secrets external-secrets external-secrets/external-secrets \
  "$ESO_CHART_VERSION" external-secrets/values.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ESO_ROLE_ARN"

# The store needs the operator's CRDs, so it is applied after the chart is ready. App-level
# ExternalSecrets (e.g. external-secrets/manifests/inventory-api-external-secret.yaml) ship with
# each app, because their namespace belongs to the app.
apply_manifest external-secrets/manifests/cluster-secret-store.yaml
