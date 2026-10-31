---
status: accepted
date: 2026-10-31
decision-makers: l-nmch
---

# Keep the svc cluster and host the frontend on it

## Context and problem statement

`svc` runs one application (Forgejo) and its control plane costs more memory than its workloads ([#264](https://github.com/phorge-fr/Hangar/issues/264)). The showcase site and the console of Phorge need a place to be served ([phorge-fr/.github#10](https://github.com/phorge-fr/.github/issues/10)), and so does their host name ([#202](https://github.com/phorge-fr/Hangar/issues/202)). Do we keep `svc`, and where does the frontend run?

## Decision drivers

* The frontend needs a cluster with a public ingress that is not `control`, which runs the platform.
* `svc` already has a public Traefik (it serves `git.phorge.fr`).
* The nodes are small (three Rock64): memory is the scarce resource, see [0002](0002-apiserver-memory.md).

## Considered options

* Keep `svc` as it is.
* Shrink `svc`.
* Merge `svc` into `core`.

## Decision outcome

Chosen option: "Keep `svc` as it is", for now, because the showcase site and the console of `phorge-fr/phorge-console` will be hosted on it. The console host name is `console.phorge.fr`.

### Consequences

* Good, because `svc` keeps a public ingress and a home for what is not the platform.
* Good, because nothing is migrated: Forgejo stays where it is.
* Bad, because the three nodes of `svc` already use 58 %, 66 % and 71 % of their memory (`kubectl top nodes`, 2026-10-31), and the frontend, and SimpleLogin ([#263](https://github.com/phorge-fr/Hangar/issues/263)) if it goes there, add to it.
* Neutral: `console.phorge.fr` needs a route on the edge HAProxy, because the edge sends an unknown host to the `control` ingress ([phorge-fr/Network#30](https://github.com/phorge-fr/Network/issues/30)).

### Confirmation

Measure the memory of the `svc` nodes before and after the frontend is deployed. Revisit this record if a node stays above 80 % or if a workload is evicted.

## Pros and cons of the options

### Keep `svc` as it is

* Good, because it costs nothing and the frontend has a place to run.
* Bad, because the control-plane memory stays high on small nodes.

### Shrink `svc`

* Good, because it frees memory.
* Bad, because it has no use until the frontend is sized, and a node removal is a change to the cluster that `k0sctl` has to apply.

### Merge `svc` into `core`

* Good, because it removes a control plane.
* Bad, because it moves Forgejo and puts a public frontend on the cluster of the platform's monitoring and authentication.

## More information

* [#264](https://github.com/phorge-fr/Hangar/issues/264), [phorge-fr/.github#10](https://github.com/phorge-fr/.github/issues/10), [#202](https://github.com/phorge-fr/Hangar/issues/202).
* The framework, the build tool and the host name of the showcase site are in [phorge-fr/.github#49](https://github.com/phorge-fr/.github/issues/49).
