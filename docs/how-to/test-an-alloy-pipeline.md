---
type: how-to
audience: maintainer changing an Alloy pipeline
verified: 2026-10-27
---

# Test an Alloy pipeline

Change the `loki.process` stages of Alloy (the geoip enrichment of the HTTP audit log, for example) without touching the real Alloy.

## Steps

1. Render the block with `helm template`.
2. Run a throwaway Alloy pod: same image, `hostNetwork` and the service account `alloy` if it must read pods, the host directory mounted read-only, the rendered block and `loki.echo` as output. Feed it newline-terminated sample files.
3. Read the output, fix, repeat. Then change the HelmRelease and let Flux apply it.

## Pitfalls

- Alloy's config goes through Helm's `tpl`: the Go template braces meant for Alloy must be written `{{ "{{" }}` and `{{ "}}" }}` in the HelmRelease, or the chart refuses to render.
- The lines read from the Kubernetes API end with a newline: the regex that appends the fields must accept it (`(\})\s*$`). A test on a file does not show it.
- `stage.drop` takes `source` as a comma-separated string, not a list.
- A template that reads a missing value writes `<no value>`: use `{{ with .x }}{{ . }}{{ end }}`.
- To test a pipeline without touching the real Alloy, run a throwaway Alloy pod (same image, `hostNetwork` and the service account `alloy` if it must read pods, the host directory mounted read-only) with the rendered block (`helm template`) and `loki.echo`. A broken reload leaves the old config running and the component `unhealthy` (Alloy UI, `/api/v0/web/components/loki.process.enrich` on the node's loopback); the mounted ConfigMap takes up to a minute to reach the pod.
- Loki rejects entries older than a week with a 400: an Alloy that restarts re-reads old lines and logs "timestamp too old", it is harmless.

## Check that it worked

A broken reload leaves the old config running and the component `unhealthy`: read it in the Alloy UI (`/api/v0/web/components/loki.process.enrich` on the node's loopback). The mounted ConfigMap takes up to a minute to reach the pod.

## Related

- [The HTTP audit log](../explanation/http-audit-log.md)
