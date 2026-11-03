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

LBC_CHART_VERSION=1.8.1

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

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo update >/dev/null

install aws-load-balancer-controller kube-system eks/aws-load-balancer-controller \
  "$LBC_CHART_VERSION" aws-load-balancer-controller/values.yaml \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$LBC_ROLE_ARN"
