# inventory-api chart

Deploys the Node.js inventory API (built and scanned by
[jenkins-ci-cd-pipeline](https://github.com/IpshitaChaudhary/jenkins-ci-cd-pipeline)) to EKS.

## Install

```bash
helm upgrade --install inventory-api charts/inventory-api \
  --namespace inventory --create-namespace \
  --set image.repository=<account>.dkr.ecr.<region>.amazonaws.com/inventory-api \
  --set image.tag=<commit-sha> \
  --atomic --timeout 5m
```

`--atomic` rolls the release back automatically if the new pods never become ready.

## What you get

| Resource | Default | Why |
|---|---|---|
| Deployment | on | Non-root, read-only rootfs, no capabilities, `RuntimeDefault` seccomp; `maxUnavailable: 0`; preStop sleep so the ALB drains before SIGTERM |
| Service | ClusterIP | Exposed only through the Ingress |
| ServiceAccount | on | Token mounted **only** when `serviceAccount.roleArn` (IRSA) is set |
| HorizontalPodAutoscaler | on, 2-6 pods @ 70% CPU | Owns the replica count; scale-down limited to 1 pod/minute after 5 min |
| PodDisruptionBudget | on, `maxUnavailable: 1` | Node drains and upgrades never take all replicas |
| NetworkPolicy | on, **deny all** | Allowed sources are explicit (`allowFromNamespaces`, `allowFromCIDRs`) |
| Ingress (ALB) | off | `ip` targets, TLS 1.3 policy, HTTP→HTTPS redirect, optional shared ALB via `groupName` |
| ServiceMonitor | off | Prometheus scrapes `/metrics` through the Service |
| PrometheusRule | off | 5xx ratio (critical, replaced by the SLO alerts when `metrics.slo` is on), missing replicas and crash loops (warning); routed to Slack by Alertmanager |
| PrometheusRule (SLO) | off | Availability SLO: SLI recording rules + multi-window burn-rate alerts (see below) |
| Grafana dashboard (ConfigMap) | off | `dashboards/inventory-api.json`, loaded by the Grafana sidecar; one release per cluster |

## Key values

| Value | Default | Notes |
|---|---|---|
| `image.repository` | `inventory-api` | ECR repository URI |
| `image.tag` | `.Chart.AppVersion` | Use the commit SHA. `latest` is rejected |
| `serviceAccount.roleArn` | `""` | IRSA role; empty = no AWS access |
| `envFrom` | `[]` | Reference existing Secrets; the chart never creates them |
| `autoscaling.enabled` | `true` | When `false`, `replicaCount` is used |
| `ingress.enabled` / `host` / `certificateArn` | `false` / `""` / `""` | `host` is required when enabled |
| `networkPolicy.allowFromNamespaces` / `allowFromCIDRs` | `[]` | With ALB `ip` targets, add the VPC CIDR |
| `metrics.serviceMonitor.enabled` / `prometheusRule.enabled` / `grafanaDashboard.enabled` | `false` | Add `monitoring` to `allowFromNamespaces` so Prometheus can scrape |
| `metrics.slo.enabled` / `objective` | `false` / `99.9` | Availability target in %, `[90, 100)` |

Every value is type-checked by `values.schema.json`.

## Availability SLO and burn-rate alerts

With `metrics.slo.enabled`, the SLI is the share of requests that return 5xx, and the error
budget is `100 - objective` (0.1% at 99.9). Alerting on how fast that budget burns, rather than on
a fixed 5xx percentage, pages for incidents that actually threaten the SLO and ignores short blips.

Each alert needs a long window (the burn is real) **and** a short window (it is still happening),
so pages fire within minutes and clear soon after the fix:

| Alert | Severity | Burn rate | Windows | Budget spent |
|---|---|---|---|---|
| `InventoryApiErrorBudgetFastBurn` | critical (page) | 14.4x | 1h and 5m | 2% in 1 hour |
| | | 6x | 6h and 30m | 5% in 6 hours |
| `InventoryApiErrorBudgetSlowBurn` | warning (ticket) | 3x | 1d and 2h | 10% in 1 day |
| | | 1x | 3d and 6h | on track to miss the SLO |

The ratio for each window is a recording rule (`slo:sli_error:ratio_rate<window>`), so the alerts
and dashboards never run `rate()` over `[3d]` themselves. Thresholds follow the Google SRE
workbook, *Alerting on SLOs*.

CI unit-tests the rendered rules with `promtool` (`ci/promtool/slo-rules-test.yaml`): a fast burn
pages, a slow burn only warns, traffic inside the budget is quiet, and a page clears once the
errors stop.

## Guard rails (enforced in CI)

The chart refuses to render when:

- `image.tag` is `latest`
- `ingress.enabled=true` without `ingress.host`
- `serviceAccount.roleArn` / `ingress.certificateArn` is not a valid ARN
- `autoscaling.minReplicas` > `maxReplicas`, or below 2
- `metrics.slo.objective` is 100 (no error budget) or below 90

## CI scenarios

`ci/*-values.yaml` are rendered and validated with kubeconform on every PR:

| File | Scenario |
|---|---|
| `default-values.yaml` | Chart defaults |
| `production-values.yaml` | IRSA + HTTPS Ingress + scoped NetworkPolicy + metrics, alerts, SLO and dashboard |
| `no-autoscaling-values.yaml` | Single replica, HPA/PDB/NetworkPolicy off |
