# 0003: GODEBUG=madvdontneed=1 on Grafana

Status: rejected.

## Context

Grafana on `core` looked memory-hungry. In theory `GODEBUG=madvdontneed=1` makes the Go runtime release pages eagerly, so reported RSS is more honest.

## Result

Tested live on the Grafana container of the monitoring HelmRelease: real memory usage **roughly doubled** instead of dropping, likely from page release and re-fault churn on this allocation pattern. Reverted immediately; nothing was committed.

## Decision

Do not enable it on Grafana, and do not assume it helps elsewhere in this repository. Memory work is root-cause-first with before/after measurements: the obvious fix made it worse here.
