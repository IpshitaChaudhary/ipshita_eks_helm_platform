# Changelog

All notable changes to this repo. Versions follow [Semantic Versioning](https://semver.org/):
while it is `0.x`, a minor release may change values keys or Application layout.
The `inventory-api` chart has its own version in `charts/inventory-api/Chart.yaml`.

## [Unreleased]

### Added

- ExternalDNS (chart 1.20.0): Route53 alias records for every Ingress host, deleted with the
  Ingress, but only records this cluster owns (TXT registry, owner ID = cluster name). Public
  zone for `EXTERNAL_DNS_DOMAIN` only; example IAM policy scoped to that zone. Argo CD wave -4.
- `ExternalDNSDown` and `ExternalDNSSyncStale` alerts with promtool tests.

### Changed

- `install.sh` now also requires `EXTERNAL_DNS_ROLE_ARN` and `EXTERNAL_DNS_DOMAIN`.

## [0.1.0] - 2026-11-14

The first complete platform: an application chart, the EKS add-ons, GitOps, and monitoring that
covers both the app and the platform.

### Application chart (`inventory-api` 0.4.0)

- Hardened Deployment (non-root, read-only root filesystem, no capabilities, `RuntimeDefault`
  seccomp), Service, ServiceAccount with IRSA. (#1)
- HPA, PodDisruptionBudget, ALB Ingress, default-deny NetworkPolicy, `values.schema.json`. (#1)
- ServiceMonitor and PrometheusRule alerts. (#4)
- Grafana dashboard shipped as a ConfigMap with the chart. (#5)
- Availability SLO: SLI recording rules and multi-window burn-rate alerts, replacing the static
  error-rate alert when enabled. (#6)

### Platform add-ons (`platform/`)

- AWS Load Balancer Controller, metrics-server, External Secrets, Karpenter (EC2NodeClass with
  IMDSv2 and encrypted gp3, NodePool with limits and disruption budget), installed in dependency
  order by `install.sh` with pinned chart versions. (#2)
- kube-prometheus-stack: EKS-aware scrape config, gp3 storage, Grafana behind an internal ALB with
  the admin login from Secrets Manager. (#4)
- Alertmanager routing to Slack by severity, with inhibit rules and the webhook from Secrets
  Manager. (#5)
- Platform self-monitoring: ServiceMonitors and alerts for External Secrets and Karpenter. (#7)
- Grafana dashboards for Karpenter and External Secrets, built with kustomize. (#8)
- Kyverno with five ClusterPolicies for app namespaces: restricted Pod Security, no `latest`
  tag, requests and a memory limit, readiness probes (Enforce), ECR-only images (Audit).
  Platform namespaces excluded; 3 admission replicas; alerts for an outage and for audit
  violations. (#9)

### GitOps (`gitops/`)

- Argo CD app-of-apps: `bootstrap.sh`, AppProjects `platform` and `apps`, one Application per
  add-on with sync waves, Argo CD managing its own upgrades. (#3)

### CI

- `helm lint` + render + kubeconform on Kubernetes 1.30 and 1.31, negative tests for the chart
  guard rails. (#1)
- Render every pinned add-on chart, shellcheck, CRD schema validation. (#2)
- Chart version drift check between `install.sh` and the Applications. (#3, #4)
- Dashboard JSON checks, `amtool check-config` and route tests. (#5)
- `promtool check rules` and alert unit tests for the app SLO and platform alerts. (#6, #7)
- Validate the kustomize build of `platform-monitoring/`; one uid per dashboard. (#8)
- `kyverno test` with pass and fail cases per policy, a guard that every policy loaded, and the
  `inventory-api` chart checked against the Enforce policies. (#9)

[Unreleased]: https://github.com/IpshitaChaudhary/ipshita_eks_helm_platform/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/IpshitaChaudhary/ipshita_eks_helm_platform/releases/tag/v0.1.0
