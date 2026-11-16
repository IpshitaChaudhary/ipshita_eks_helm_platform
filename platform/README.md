# Platform add-ons

Cluster-level components that application charts in `charts/` depend on. Each add-on has its own
folder with a pinned values file, and `install.sh` installs them in dependency order with pinned
chart versions, so a cluster can be rebuilt exactly.

| Add-on | Why the apps need it | Chart | Version |
|---|---|---|---|
| metrics-server | Feeds CPU/memory to the HorizontalPodAutoscaler | `metrics-server/metrics-server` | 3.12.1 |
| AWS Load Balancer Controller | Turns `Ingress` (class `alb`) into an ALB with target-type `ip` | `eks/aws-load-balancer-controller` | 1.8.1 |
| ExternalDNS | Points each Ingress host at its ALB in Route53, removes the record with the Ingress | `external-dns/external-dns` | 1.20.0 |
| External Secrets | Syncs AWS Secrets Manager into the Secrets apps read with `envFrom` | `external-secrets/external-secrets` | 0.10.7 |
| Karpenter | Adds right-sized nodes when pods are pending, removes them when idle | `oci://public.ecr.aws/karpenter/karpenter` | 1.1.7 |
| kube-prometheus-stack | Prometheus, Alertmanager and Grafana; scrapes the apps' ServiceMonitors | `prometheus-community/kube-prometheus-stack` | 65.1.1 |
| Kyverno | Rejects app pods that break the workload guardrails (`kyverno/policies/`) | `kyverno/kyverno` | 3.4.6 |

## Prerequisites

- An EKS cluster with an IAM OIDC provider (the `eks` module in
  [ipshita_terraform_infrastructure_module](https://github.com/IpshitaChaudhary/ipshita_terraform_infrastructure_module)
  creates both).
- One IRSA role per add-on, trusted only by that add-on's ServiceAccount. Add-ons never use the
  node role: a compromised pod on the node must not inherit load-balancer or secret permissions.
- The `aws-ebs-csi-driver` EKS add-on (the monitoring volumes use the `gp3` StorageClass).
- `helm` 3.14+ and `kubectl` pointed at the cluster.

## Install

```bash
export CLUSTER_NAME=example-cluster
export AWS_REGION=us-east-1
export VPC_ID=vpc-0123456789abcdef0
export LBC_ROLE_ARN=arn:aws:iam::111122223333:role/example-cluster-aws-lbc
export EXTERNAL_DNS_ROLE_ARN=arn:aws:iam::111122223333:role/example-cluster-external-dns
export EXTERNAL_DNS_DOMAIN=example.com
export ESO_ROLE_ARN=arn:aws:iam::111122223333:role/example-cluster-external-secrets
export KARPENTER_ROLE_ARN=arn:aws:iam::111122223333:role/example-cluster-karpenter
export KARPENTER_QUEUE=example-cluster-karpenter-interruptions

./platform/install.sh                 # install or upgrade everything, in order
./platform/install.sh --dry-run       # render only, nothing is applied
```

## Design notes

- **Region and VPC are set explicitly** for the load balancer controller. Without them it asks the
  instance metadata service, which fails when IMDSv2 hop limit is 1 (as it should be on EKS nodes).
- **The Service mutator webhook is off.** Otherwise the controller takes over every
  `type: LoadBalancer` Service in the cluster, including ones meant for the legacy cloud provider.
- **Two replicas and a PDB** for every controller, so a node drain never removes the only copy.
  ExternalDNS is the exception: it has no leader election, so it runs one replica. While it is
  down only DNS *changes* wait; every existing record keeps resolving.
- **ExternalDNS only touches what it created.** Policy `sync` removes a record when its Ingress
  goes, so no record is left pointing at a deleted load balancer. It is safe because of the TXT
  registry: each record gets an ownership TXT (`extdns-` prefix) with the cluster name, and
  ExternalDNS never changes a record without one, so hand-made records and other clusters'
  records in the same zone are left alone. It is limited to the public zone for
  `EXTERNAL_DNS_DOMAIN`, and its IRSA role can change only that zone
  (`external-dns/iam-policy.json`).
- **Secrets never pass through Git or Helm values.** External Secrets reads them from Secrets
  Manager at runtime; the IAM role should allow `secretsmanager:GetSecretValue` only on `app/*` and `platform/*`.
  The synced Secret is kept (`deletionPolicy: Retain`) if the ExternalSecret is removed, so a bad
  rollout of the operator can't delete a running app's credentials.
- **Karpenter nodes are locked down the same way as the managed nodes:** IMDSv2 only with hop
  limit 1, encrypted gp3 root disk, and subnets/security groups found by tag instead of hard-coded
  IDs. The NodePool caps total CPU and memory, replaces nodes every 30 days so AMI patches roll
  out, and never disrupts more than 10% of nodes at once.
- **Monitoring skips what EKS hides.** The scheduler, controller-manager, etcd and kube-proxy
  targets are off: on EKS they are unreachable, so they would only raise a `TargetDown` alert
  nobody can fix. Prometheus selects ServiceMonitors and rules from every namespace, so an app
  chart only has to ship its own (no release label to keep in sync).
- **Prometheus can't fill its disk.** 15 days or 45 GB on a 50 GiB encrypted gp3 volume, whichever
  comes first. Grafana's admin login comes from Secrets Manager (`platform/grafana-admin`), and it
  is reachable only through an internal ALB.
- **Alerts reach people, plumbing doesn't.** Alertmanager sends `critical` to `#alerts-critical`
  (repeats hourly) and everything else to `#alerts-warning` (every 4 hours). `Watchdog`,
  `InfoInhibitor` and `info` alerts go to a null receiver, and a critical alert inhibits the
  warning with the same name. The Slack webhook comes from Secrets Manager
  (`platform/alertmanager-slack`, key `webhook-url`) and is read from a mounted file.
- **The platform watches itself.** `kube-prometheus-stack/platform-monitoring/` scrapes External
  Secrets, Karpenter, Kyverno, ExternalDNS and Argo CD and alerts when they stop doing their job.
  It is applied after kube-prometheus-stack (last in `install.sh`, wave 0 in Argo CD) because
  those add-ons install before the ServiceMonitor CRD exists (Argo CD's own chart ServiceMonitors
  stay off for the same reason). Rules are unit-tested with `promtool`
  (`kube-prometheus-stack/tests/`).

  | Alert | Severity | What it means for workloads |
  |---|---|---|
  | `ExternalSecretNotReady` | warning | A Secret is stale (rotated credentials not picked up) or was never created |
  | `ExternalSecretsControllerDown` | warning | No Secret is refreshed or created until it is back |
  | `KarpenterControllerDown` | critical | No scale-out; Spot interruptions are not drained |
  | `KarpenterCloudProviderErrors` | warning | EC2 calls failing (capacity, quotas, IAM, discovery tags) |
  | `KarpenterNodePoolNearLimit` | warning | Above 90% of the NodePool CPU limit; at 100% pods stay Pending |
  | `KyvernoAdmissionControllerDown` | critical | No pod can be created or changed in app namespaces |
  | `KyvernoAuditViolations` | warning | A workload breaks an Audit-mode policy and would be rejected once it is enforced |
  | `ExternalDNSDown` | warning | New or changed Ingress hosts get no DNS record; existing ones keep resolving |
  | `ExternalDNSSyncStale` | warning | Running, but nothing reached Route53 for 10 minutes (IAM, zone, throttling) |
  | `ArgoCDControllerDown` | warning | Nothing syncs from Git: merges are not deployed, manual changes not reverted |
  | `ArgoCDAppNotSynced` | warning | An Application is OutOfSync or Unknown for 30 minutes despite automated sync |
  | `ArgoCDAppUnhealthy` | warning | An Application is Degraded or Missing for 15 minutes |

  Each alert has a matching panel in a Grafana dashboard, so the page links to its explanation:
  **Platform / Karpenter** (pending pods, NodePool CPU against its limit, node churn, disruption
  decisions, Spot interruptions, EC2 errors) and **Platform / External Secrets** (ready / not ready,
  a table of what is failing right now, sync errors, Secrets Manager calls by status) and
  **Platform / Argo CD** (Applications not synced or not healthy with a table naming them, sync
  results, reconcile time, repo-server Git latency, by project). The JSON lives
  in `platform-monitoring/dashboards/`; the directory is a kustomization that turns each file into a
  `grafana_dashboard` ConfigMap, built the same way by Argo CD and `install.sh`. To change a
  dashboard, edit it in Grafana, export the JSON, set every panel's data source to `${datasource}` and
  open a PR: UI edits are not saved, and CI rejects hardcoded data sources and duplicate uids.
- **Guardrails for app namespaces (Kyverno).** `kyverno/policies/` holds the rules every app must
  follow, applied by `install.sh` after the chart and by Argo CD in wave -2, before any app:

  | Policy | Mode | Rejects |
  |---|---|---|
  | `pod-security-restricted` | Enforce | Pods below the restricted Pod Security Standard |
  | `disallow-latest-tag` | Enforce | Images with no tag or `:latest` (a digest is fine) |
  | `require-requests-limits` | Enforce | Containers without CPU/memory requests or a memory limit |
  | `require-readiness-probe` | Enforce | Deployments and StatefulSets without a readiness probe |
  | `restrict-image-registries` | Audit | Images not from ECR or ECR Public (reported, not blocked yet) |

  Pod rules also apply to Deployments, Jobs and the other controllers (Kyverno autogen), so a bad
  Deployment is rejected at `kubectl apply` / Argo CD sync, not stuck later with zero pods.
  Platform namespaces (kube-system, argocd, external-secrets, monitoring, kyverno) are excluded in
  `kyverno/values.yaml`, so Kyverno can never block the controllers that run the cluster. App
  namespaces fail closed, which is why the admission controller runs 3 replicas with a PDB and
  pages when it is down. To add a policy: a file in `kyverno/policies/`, listed in its
  `kustomization.yaml`, with pass and fail cases in `kyverno/tests/` (CI runs `kyverno test`, and
  checks that the `inventory-api` chart still passes every Enforce policy).
