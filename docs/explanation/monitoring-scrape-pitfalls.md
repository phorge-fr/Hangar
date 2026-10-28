---
type: explanation
audience: maintainer adding a scrape or a dashboard on Flux objects
verified: 2026-10-28
---

# Monitoring scrape pitfalls

Pitfalls met adding Flux, Longhorn and cert-manager scrapes that the manifests do not show. PodMonitors are shared in `base/apps/monitoring/`.

- **Longhorn manager listens on the pod IP only**, not on localhost: `kubectl port-forward` returns an empty reply. Read metrics through the API server proxy: `kubectl get --raw /api/v1/namespaces/longhorn-system/pods/<pod>:9500/proxy/metrics` (fast only for the manager on the API server's own node). Chart 1.12.1 creates restrictive NetworkPolicies even with `networkPolicies.enabled: false`, hence the extra `longhorn-manager-metrics` policy for Prometheus.
- **Alloy on `control` and `svc` is hostNetwork**: cross-node scrapes arrive with the `remote-node` identity, which Kubernetes NetworkPolicies do not match. Symptom: only the targets on Alloy's node are up. Fix: a `CiliumNetworkPolicy` with `fromEntities: [host, remote-node]`. Any new policy-protected namespace scraped by Alloy needs it.
- **kube-state-metrics does not restart when its custom-resource-state ConfigMap changes** (no checksum annotation): `kubectl rollout restart` it on each cluster, otherwise the pod keeps the old configuration while `spec.values` looks right. The Flux block lives in two files, `overlays/core/apps/kube-prometheus-stack/kube-prometheus-stack.yml` and `base/controllers/kube-state-metrics/kube-state-metrics.yml`: change both.
- **`namespace` versus `exported_namespace`**: PodMonitor scrapes keep `namespace` as the scraped pod's and rename the metric's own to `exported_namespace` (cert-manager Certificates, `gotk_*` from `gotk_reconcile_duration_seconds`). `gotk_resource_info` carries `exported_namespace` by explicit configuration; its `namespace` exists on `core` only, so rules and dashboards must not use it for Flux objects.
- **The Flux `suspended` label is absent when not suspended**: match with `suspended!="true"` and `suspended="true"`.
- The Flux kube-state-metrics configuration is the upstream `flux2-monitoring-example` minus `image.*` and minus the Receivers' `webhook_path` (a secret).
