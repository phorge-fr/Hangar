# Hangar

![Phorge logo](https://avatars.githubusercontent.com/u/187407936?s=200&v=4)

GitOps repository for all Phorge Kubernetes clusters, managed with [FluxCD](https://fluxcd.io/) and [SOPS](https://getsops.io/).

## Clusters

| Cluster | Role | Description |
|---------|------|-------------|
| [Control](clusters/control/setup/README.md) | Control Plane | Main entry point of the infrastructure. Handles user-facing resource provisioning (VMs, etc.), serves as the AI model gateway, and hosts the infrastructure frontend. |
| [SVC](clusters/svc/setup/README.md) | Public Services | Exposes end-user services to the internet (Forgejo, Open WebUI, etc.). |
| [Core](clusters/core/setup/README.md) | Infrastructure Core | Hosts critical internal services: monitoring, logging, authentication & authorization. |

## Repository Structure

```
base/          # Shared base manifests (controllers, configs, apps)
clusters/      # Per-cluster Flux entrypoints and setup guides
overlays/      # Per-cluster Kustomize overlays
```

Each cluster's overlay is split into up to four categories, each its own Flux `Kustomization`
with its own dependency on the previous one (`overlay-controllers` -> `overlay-configs` -> `apps`):

| Category | Content |
|----------|---------|
| `controllers/` | Cluster-wide operators and platform components (Traefik, Alloy, Crossplane...) |
| `configs/` | Configuration objects for controllers already installed (ClusterIssuers, StorageClasses...) |
| `apps/` | Workloads that run in this cluster |
| `resources/` | Resources Crossplane provisions outside this cluster (Incus, OpenFGA...), not Kubernetes workloads. Depends on `overlay-controllers` directly, not the full chain - its only real prerequisite is Crossplane and its providers being installed |

## Metrics labels

Every series in the central Prometheus (on core) carries the same labels, whether it was scraped natively on core or pushed by Alloy from the other clusters and the storage node:

| Label | Meaning |
|-------|---------|
| `cluster` | `control`, `core`, `svc`, `stor` or `comp` |
| `node` | Machine hostname, on node-level series (node-exporter, kubelet, cAdvisor, scheduler, controller-manager) |
| `instance` | Machine hostname for node-exporter, kubelet, scheduler and controller-manager, scrape address (`IP:port`) for everything else |
| `exported_namespace` | Namespace of the object a series describes, where `namespace` is already the one of the pod that is scraped: the Certificates of cert-manager and the Flux objects |

On core, `cluster=core` comes from the default scrape class in `overlays/core/apps/kube-prometheus-stack/`. On the other clusters it is the `cluster` external label that Alloy sets from its `CLUSTER_NAME` variable (`base/controllers/alloy/`).

## Tooling

| Tool | Purpose |
|------|---------|
| [k0sctl](https://github.com/k0sproject/k0sctl/) | Kubernetes cluster provisioning |
| [Cilium](https://cilium.io/) | CNI — networking & L2 load balancing |
| [FluxCD](https://fluxcd.io/) | GitOps continuous delivery |
| [Mozilla SOPS](https://getsops.io/) + [age](https://github.com/FiloSottile/age) | Secret encryption |