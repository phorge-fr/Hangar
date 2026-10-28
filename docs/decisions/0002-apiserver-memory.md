---
status: accepted
date: 2026-10-24
decision-makers: l-nmch
---

# Bound the kube-apiserver memory with GOMEMLIMIT

## Context and problem statement

On `control` and `svc` the Kubernetes control-plane processes together use more memory than every application pod, because every node is both controller and worker. The `kube-apiserver` is the largest process on all nine nodes (700 MiB to 1.6 GiB). Object counts are tiny; the default watch cache reserves slots per registered resource type and these clusters register more than 130 types (CRDs). With `GOGC=100` and no limit, the Go heap target is about twice the live heap. Can the memory be reduced with low risk?

## Decision drivers

* Low incidence: a change to the API server restarts it, node by node.
* Decide from measurements, not theory (a similar experiment, [GODEBUG on Grafana](0003-godebug-madvdontneed-rejected.md), doubled the memory).
* Keep the change in Git.

## Considered options

* `default-watch-cache-size: "20"` on the API server.
* `GOMEMLIMIT` through a systemd drop-in for `k0scontroller`.
* Do nothing and size the nodes for it.

## Decision outcome

Chosen option: "`GOMEMLIMIT` per cluster", set through `k0sctl` `files`: `svc` 850 MiB, `core` 900 MiB, `control` 1100 MiB (about 1.5 times the peak live heap). A tighter limit only trades CPU for memory.

### Consequences

* Good, because measured against a plainly restarted node over 18 hours, RSS fell 8 % on average and 16 % at the peak.
* Bad, because the garbage collector runs more often near the limit: a 700 MiB limit on `svc` made GC CPU spike up to four times higher, hence 850.
* Neutral: roll out one node at a time with `k0sctl` ([behavior](../explanation/k0sctl-apply-behavior.md)). Re-measure after any change in the number of registered CRDs.

### Confirmation

`GOMEMLIMIT` is visible in `/proc/<pid>/environ` of the API server on every node (issue #203, pull request #204).

## Pros and cons of the options

### default-watch-cache-size 20

* Good, because it targets the cause.
* Bad, because the early read (about -20 % RSS on two of three nodes) was not conclusive at steady state.

### GOMEMLIMIT

* Good, because it is measurable and reversible.
* Bad, because it must be tuned per cluster.

### Do nothing

* Good, because no risk.
* Bad, because the control plane keeps outweighing the workloads on small nodes.

## More information

* The kubelet leak seen earlier on `core` is gone (about 1 GiB a month before, about 100 MiB after).
* `alloy-cluster` memory is mostly the scrape cache and staleness tracking and scales with label churn.
* 33 of 41 kubelet histogram series are used by no dashboard (about 7,300 series could be dropped). The maintainer **declined** this; it stays a known, scoped option.
* The `resource` label of the API server series is used by the stock API server dashboard: not a free win.
