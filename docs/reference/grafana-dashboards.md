---
type: reference
audience: maintainer adding or looking for a Grafana dashboard
verified: 2026-11-07
---

# Grafana dashboards: folders and tags

Every dashboard of the `core` Grafana is provisioned from this repository and sits in a folder. Nothing is created by hand in the interface: the sidecar deletes what is no longer in Git (`enableDeletion`).

## Folders

| Folder | What it holds |
| --- | --- |
| Alerting | The alerts that are firing |
| Cluster health | What every cluster needs to run: overview, Flux, Crossplane, cert-manager, Longhorn |
| Compute | Incus and Ceph |
| Core | The services of the `core` cluster and their audit logs: Authentik, OpenFGA, the HTTP and Kubernetes audit logs |
| Kubernetes | The dashboards of the `kube-prometheus-stack` chart: API server, kubelet, resources, networking, nodes, etcd |
| Network | The router |
| Service | Forgejo |
| Storage | RustFS |

## Tags

A dashboard has one tag for its component (`flux`, `longhorn`, `openfga`) and, when it applies:

- `logs` when the data comes from Loki;
- `audit` and `security` for the audit dashboards;
- `comp` for the compute nodes.

The dashboards of the chart carry the tags the chart gives them.

## Where the files are

| What | Where |
| --- | --- |
| Our dashboards | `overlays/core/apps/kube-prometheus-stack/grafana-dashboards/`, one `ConfigMap` per dashboard |
| The folder of ours | The `grafana_folder` annotation of the `ConfigMap` |
| The folder of the chart's | `grafana.sidecar.dashboards.annotations` in `kube-prometheus-stack.yml` |
| The tags | The `tags` key of the dashboard JSON |

The chart's dashboards that are not wanted are removed in `kube-prometheus-stack.yml`: the AIX and macOS node dashboards through `nodeExporter.operatingSystems`, and Grafana Overview (no switch in the chart) through a `postRenderers` patch.

## Add a dashboard

1. Create the `ConfigMap` with the label `grafana_dashboard: "1"` and the `grafana_folder` annotation set to a folder of the table above. A new folder is a new row in that table.
2. Give the JSON a stable `uid` and its `tags`.
3. List the file in the `kustomization.yml` of `grafana-dashboards/`.
4. Prove that it renders, see [Check a Grafana dashboard](../how-to/check-a-grafana-dashboard.md).
