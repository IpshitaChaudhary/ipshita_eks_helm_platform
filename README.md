# ipshita_eks_helm_platform

Helm charts and platform add-ons for running workloads on **Amazon EKS** the way I run them in production:
secure by default, observable, and safe to roll out and roll back.

The EKS cluster itself is built with the `eks` module from
[ipshita_terraform_infrastructure_module](https://github.com/IpshitaChaudhary/ipshita_terraform_infrastructure_module).
This repo covers what runs **on** the cluster.

## Layout

```
charts/
  inventory-api/     # application chart (the Node.js API from jenkins-ci-cd-pipeline)
platform/            # cluster add-ons: pinned values, manifests and an ordered install.sh
gitops/              # Argo CD app-of-apps: bootstrap.sh, root app, projects, one Application per add-on/app
.github/workflows/   # helm lint + render + kubeconform on every PR
```

## Quick start

```bash
helm lint charts/inventory-api --strict
helm template demo charts/inventory-api -f charts/inventory-api/ci/production-values.yaml
```

See [charts/inventory-api/README.md](charts/inventory-api/README.md) for install and values.

## GitOps with Argo CD

Two ways to install the platform, from the same pinned chart versions and values files:

- `platform/install.sh`: imperative, for a cluster without Argo CD.
- `gitops/bootstrap.sh`: installs Argo CD only and applies `gitops/root-app.yaml`. From then on Argo CD
  installs and upgrades everything from `main`, including itself. Changes go through a PR, never `kubectl`.

```bash
./gitops/bootstrap.sh --dry-run   # render only
./gitops/bootstrap.sh             # install Argo CD and hand the cluster to Git
```

Sync waves bring the cluster up in order, and Argo CD waits for each wave to be Healthy:

| Wave | What |
|---|---|
| -10 | AppProjects `platform` and `apps`, Karpenter OCI repository |
| -5 | Argo CD (manages its own upgrades) |
| -4 | metrics-server, AWS Load Balancer Controller |
| -3 | External Secrets, Karpenter (operators + CRDs) |
| -2 | ClusterSecretStore, EC2NodeClass + NodePool, monitoring StorageClass + Grafana secret |
| -1 | kube-prometheus-stack (its CRDs must exist before apps ship ServiceMonitors) |
| 0 | inventory-api + its ExternalSecret |

Per cluster, only the values in `gitops/apps/*.yaml` change (cluster name, region, VPC, IRSA role ARNs);
CI fails if an Application and `install.sh` pin different chart versions.

## Principles

- **Secure defaults, opt-out not opt-in.** Non-root, read-only root filesystem, all capabilities dropped,
  `RuntimeDefault` seccomp, no service-account token unless the pod needs AWS access.
- **AWS access through IRSA**, never node-role permissions or static keys in values files.
- **Zero-downtime rollouts.** `maxUnavailable: 0`, readiness probes, PodDisruptionBudget,
  spread across nodes and AZs.
- **Everything renders in CI.** Every chart change is linted, templated and validated against the
  Kubernetes schema before it can merge.
- **No secrets in Git.** Charts reference existing Secrets (or External Secrets); values files never carry credentials.

## Roadmap

| Step | Status |
|---|---|
| Repo skeleton | Done |
| `inventory-api` chart: Deployment, Service, ServiceAccount (IRSA) | Done |
| HPA, PDB, ALB Ingress, NetworkPolicy, values schema | Done |
| CI: `helm lint`, `helm template` + kubeconform, negative tests | Done |
| Platform add-ons: AWS Load Balancer Controller, metrics-server, External Secrets, Karpenter | Done |
| CI: shellcheck, render every pinned add-on chart, CRD schema validation | Done |
| GitOps with Argo CD (app-of-apps), AppProjects, sync waves | Done |
| CI: render Argo CD, validate Applications, chart version drift check | Done |
| Observability: kube-prometheus-stack, alerts, dashboards | Planned |
