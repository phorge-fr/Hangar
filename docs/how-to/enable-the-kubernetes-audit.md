---
type: how-to
audience: maintainer turning the audit on, or changing its policy, on a cluster
verified: 2026-10-28
---

# Enable the Kubernetes audit on a cluster

Everything that Flux manages (Alloy, the dashboard) is deployed by the merge and does nothing until the file exists. The API server changes with `k0sctl apply`, following the procedure in the README of the cluster (`clusters/<cluster>/setup/README.md`); [How k0sctl apply behaves](../explanation/k0sctl-apply-behavior.md) says what the tool does and what was measured. Short version: one cluster at a time, `svc`, then `core`, then `control`; it stops and starts the k0s service of every controller one after the other, and the API server of each node is down for 30 to 90 seconds. Do not do it on `control` while the end-to-end tests of the API run. A change of `clusters/audit-policy.yaml` needs the same (the API server reads it when it starts).

`svc` was first configured by hand on 2026-10-27, before the dry run showed what `k0sctl apply` does; the apply of 2026-10-28 brought it back to what Git says. To check the audit afterwards: `ssh root@<node> 'tail -n1 /var/lib/k0s-audit/audit.log'`, and in Grafana `{job="k8s-audit", cluster="<cluster>"}` has lines from the three nodes.

## Related

- [The Kubernetes audit log](../explanation/kubernetes-audit-log.md)
