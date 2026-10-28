---
status: rejected
date: 2026-09-15
decision-makers: l-nmch
---

# GODEBUG madvdontneed=1 on Grafana

## Context and problem statement

Grafana on `core` looked memory-hungry. In theory `GODEBUG=madvdontneed=1` makes the Go runtime release pages eagerly, so the reported RSS is more honest. Does it lower real memory use?

## Considered options

* Set `GODEBUG=madvdontneed=1` on the Grafana container.
* Leave the Go runtime defaults.

## Decision outcome

Chosen option: "leave the defaults", because the experiment **roughly doubled** Grafana's real memory use instead of reducing it, likely from page release and re-fault churn on this allocation pattern. It was reverted at once; nothing was committed.

### Consequences

* Good, because memory work stays root-cause-first with before/after measurements: the obvious fix made it worse here.
* Bad, because Grafana's memory question stays open.

## More information

Related: [bound the API server memory](0002-apiserver-memory.md), which was decided from measurements.
