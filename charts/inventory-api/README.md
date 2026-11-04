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

Every value is type-checked by `values.schema.json`.

## Guard rails (enforced in CI)

The chart refuses to render when:

- `image.tag` is `latest`
- `ingress.enabled=true` without `ingress.host`
- `serviceAccount.roleArn` / `ingress.certificateArn` is not a valid ARN
- `autoscaling.minReplicas` > `maxReplicas`, or below 2

## CI scenarios

`ci/*-values.yaml` are rendered and validated with kubeconform on every PR:

| File | Scenario |
|---|---|
| `default-values.yaml` | Chart defaults |
| `production-values.yaml` | IRSA + HTTPS Ingress + scoped NetworkPolicy |
| `no-autoscaling-values.yaml` | Single replica, HPA/PDB/NetworkPolicy off |
