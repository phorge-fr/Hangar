# 0002: Bound the kube-apiserver memory with GOMEMLIMIT

Status: accepted, versioned in each `clusters/<cluster>/setup/k0s-cluster.yml` (issue #203, pull request #204).

## Context

On `control` and `svc` the Kubernetes control-plane processes together use more memory than every application pod (every node is both controller and worker). The `kube-apiserver` is the largest process on all nine nodes (700 MiB to 1.6 GiB). Object counts are tiny; the cause is the default watch cache, which reserves slots per registered resource type, and these clusters register more than 130 types (CRDs). With `GOGC=100` and no limit, the Go heap target is about twice the live heap.

## What was tried

- `default-watch-cache-size: "20"` (on `control`): early read about -20 % RSS on two of three nodes; not conclusive at steady state.
- `GOMEMLIMIT` through a systemd drop-in for `k0scontroller`: measured against a plainly restarted node over 18 hours, RSS average -8 %, maximum -16 %, average CPU and GC CPU unchanged, but GC CPU spikes up to four times higher when the limit sits close to the peak live heap (a 700 MiB limit on `svc` was too tight).

## Decision

`GOMEMLIMIT` per cluster, set through `k0sctl` `files`: `svc` 850 MiB, `core` 900 MiB, `control` 1100 MiB (about 1.5 times the peak live heap). A tighter limit only trades CPU for memory.

## Related findings

- The kubelet leak seen earlier on `core` is gone (about 1 GiB a month before, about 100 MiB after).
- `alloy-cluster` memory is mostly the scrape cache and staleness tracking; it scales with label churn from pod restarts.
- 33 of 41 kubelet histogram series are referenced by no dashboard (about 7,300 series could be dropped). This was explicitly **declined**; it stays a known, scoped option if cardinality comes up again.
- `kube-apiserver` `resource` label cardinality is used by the stock API server dashboard: not a free win.

## Consequences

Roll a change one node at a time with `k0sctl` ([procedure](../k0sctl-apply.md)). Re-measure after any change of the number of registered CRDs.
