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
: "${KARPENTER_ROLE_ARN:?set KARPENTER_ROLE_ARN (IRSA role for the Karpenter controller)}"
: "${KARPENTER_QUEUE:?set KARPENTER_QUEUE (SQS interruption queue name)}"

LBC_CHART_VERSION=1.8.1
METRICS_SERVER_CHART_VERSION=3.12.1
ESO_CHART_VERSION=0.10.7
KARPENTER_CHART_VERSION=1.1.7
KUBE_PROMETHEUS_STACK_CHART_VERSION=65.1.1
KYVERNO_CHART_VERSION=3.4.6

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

# apply_manifest <file>: manifests are written for example-cluster in us-east-1; the real
# cluster name and region come from the environment, so no file needs editing per cluster.
apply_manifest() {
  local rendered
  rendered=$(sed -e "s/region: us-east-1/region: ${AWS_REGION}/" \
                 -e "s/example-cluster/${CLUSTER_NAME}/g" "$1")
  if $DRY_RUN; then
    printf '%s\n' "$rendered"
  else
    printf '%s\n' "$rendered" | kubectl apply -f -
  fi
}

# apply_kustomization <dir>: the same build Argo CD makes from that directory.
apply_kustomization() {
  if $DRY_RUN; then
    kubectl kustomize "$1"
  else
    kubectl apply -k "$1"
  fi
}

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update >/dev/null
helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno --force-update >/dev/null
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

# Monitoring: the gp3 class its volumes use and the Grafana admin Secret must exist before the
# chart, or the Prometheus PVC stays Pending and Grafana can't start (and Alertmanager can't mount
# its Slack webhook Secret).
apply_manifest kube-prometheus-stack/manifests/storageclass-gp3.yaml
if ! $DRY_RUN; then
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
fi
apply_manifest kube-prometheus-stack/manifests/grafana-admin-external-secret.yaml
apply_manifest kube-prometheus-stack/manifests/alertmanager-slack-external-secret.yaml
install kube-prometheus-stack monitoring prometheus-community/kube-prometheus-stack   "$KUBE_PROMETHEUS_STACK_CHART_VERSION" kube-prometheus-stack/values.yaml

# Karpenter last: everything above runs on the managed node group, and nodes Karpenter adds are
# only useful once the controllers that serve their pods exist.
install karpenter kube-system oci://public.ecr.aws/karpenter/karpenter \
  "$KARPENTER_CHART_VERSION" karpenter/values.yaml \
  --set settings.clusterName="$CLUSTER_NAME" \
  --set settings.interruptionQueue="$KARPENTER_QUEUE" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$KARPENTER_ROLE_ARN"

apply_manifest karpenter/manifests/ec2nodeclass.yaml
apply_manifest karpenter/manifests/nodepool.yaml

# Admission policies for app namespaces. Platform namespaces are excluded in kyverno/values.yaml,
# so installing Kyverno can't block any of the add-ons above.
install kyverno kyverno kyverno/kyverno "$KYVERNO_CHART_VERSION" kyverno/values.yaml
# The policies need Kyverno's CRDs and a ready webhook; install() waits for both (--wait).
apply_kustomization kyverno/policies

# Scrape configs, alerts and dashboards for the add-ons themselves. Last, because they need the
# ServiceMonitor/PrometheusRule CRDs from kube-prometheus-stack and target Karpenter's Service.
apply_kustomization kube-prometheus-stack/platform-monitoring
