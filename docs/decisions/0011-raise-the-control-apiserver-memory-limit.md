---
status: accepted
date: 2026-11-01
decision-makers: l-nmch
---

# Raise the memory limit of the control API servers to 1400 MiB

## Context and problem statement

[0002](0002-apiserver-memory.md) set `GOMEMLIMIT` to 1100 MiB for the API servers of `control`, about 1.5 times the peak live heap measured then, and noted that a limit that is too tight only trades memory for CPU. On 2026-11-01 two of the three API servers began to use about 3.2 cores each ([Hangar#308](https://github.com/phorge-fr/Hangar/issues/308)). The nodes `ctrl-rpi4-01` and `ctrl-rpi4-02` were at 98 % CPU.

The first rise (`10.1.0.2`, 01:18 UTC) came with the installation of a Crossplane provider that registers 219 CRDs, the second (`10.1.0.1`, about 16:00 UTC) with the removal of that provider and the installation of another. Removing the CRDs did not bring the CPU back.

## Decision drivers

* Decide from measurements ([0002](0002-apiserver-memory.md), [0003](0003-godebug-madvdontneed-rejected.md)).
* The nodes are controllers and workers at once, with about 1 GiB of memory available.
* A restart of the API servers is an apply of the cluster, one node at a time.

## Considered options

* Keep 1100 MiB and restart the API servers.
* Raise the limit to 1400 MiB and restart the API servers.
* Remove the limit.

## Decision outcome

Chosen option: "raise the limit to 1400 MiB", about 1.8 times the peak live heap of about 770 MiB, with a restart of the three controllers through `k0sctl apply --concurrency 1`.

Measured on 2026-11-01, after the CRDs were removed:

| API server | Live heap | Heap in use | RSS | GC per second | CPU (cores) |
| --- | --- | --- | --- | --- | --- |
| `10.1.0.1` | 731 MiB | 1047 MiB | 1152 MiB | 1.1 | 3.1 |
| `10.1.0.2` | 668 MiB | 972 MiB | 1064 MiB | 1.3 | 3.2 |
| `10.1.0.3` | 535 MiB | 808 MiB | 1011 MiB | 0.02 | 0.1 |

The live heap is back to the level of 0002, but the heap in use is 300 MiB larger than the live heap: the memory is fragmented by the load and unload of the CRDs, and the Go garbage collector does not compact it. With the stacks, the process sits at the 1100 MiB limit and the collector runs continuously. The request rate is low (2 to 3 per second), Crossplane is quiet and etcd uses 0.15 core, so the cost is the collector. The API servers had not restarted since 2026-10-28, so nothing reset the fragmentation.

### Consequences

* Good, because the live heap plus the fragmentation seen here (about 1150 MiB with the stacks) fits under the limit with a margin of 250 MiB.
* Good, because the restart clears the fragmentation that the higher limit alone would not.
* Bad, because the API server may use 300 MiB more, on nodes that have about 1 GiB available.
* Bad, because the value is a response to one measurement: another burst of CRDs can fragment the heap again. The number of CRDs that Crossplane registers (171 on `control`) is the cause and is a separate subject.

### Confirmation

One hour after the restart, on every node: the process environment holds `GOMEMLIMIT=1400MiB`, the CPU of the apiserver job is under 0.5 core, and `go_gc_duration_seconds_count` grows by less than 0.1 per second. If it does not hold, revisit the number of CRDs before the limit.

## Pros and cons of the options

### Keep 1100 MiB and restart the API servers

* Good, because nothing changes in the configuration.
* Bad, because the process was at the limit with the live heap at its normal level: the next burst of CRDs brings the collector back.

### Raise the limit to 1400 MiB and restart the API servers

* Good, because it leaves room for the fragmentation seen here.
* Bad, because of the memory used, see Consequences.

### Remove the limit

* Good, because the collector no longer runs against a ceiling.
* Bad, because 0002 measured the heap reaching about twice the live heap without it, on nodes that run workloads.
