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
platform/            # cluster add-ons: values + install notes (planned)
.github/workflows/   # helm lint + render + schema validation on every PR (planned)
```

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
| `inventory-api` chart: Deployment, Service, ServiceAccount (IRSA) | Planned |
| HPA, PDB, ALB Ingress, NetworkPolicy, values schema | Planned |
| CI: `helm lint`, `helm template` + kubeconform | Planned |
| Platform add-ons: AWS Load Balancer Controller, metrics-server, External Secrets, Karpenter | Planned |
| GitOps with Argo CD (app-of-apps) | Planned |
