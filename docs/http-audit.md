# HTTP audit log (Traefik)

Every HTTP request that reaches a cluster through Traefik is written as a JSON line, collected into Loki, enriched with the country and the network of the client, and read in Grafana by the dashboard "HTTP audit (Traefik)" (folder Core, uid `http-audit`). It answers: who comes (address, country, network, user agent), to whom (host, service), and why a request failed.

State: **core only**. `control` and `svc` are not done yet, see the last section.

## How it works

1. **Traefik** (`traefik-public` and `traefik-local`, `overlays/core/controllers/traefik/*-patch.yml`) writes the access log in JSON on its standard output. Alloy already ships every pod log of every cluster to the Loki of core, so nothing else collects it. Only the `User-Agent` header is kept (never `Authorization` or `Cookie`), the `Referer` is dropped and so is the query string of the path (`queryParameters.defaultMode: drop`, Traefik 3.7.3+): it can hold an OAuth code, a state or a device code.
2. **Alloy** (`overlays/core/controllers/alloy/alloy.yml`, `loki.process "enrich"`) takes the lines of the namespace `traefik` that carry a `ClientHost`, looks the address up in two DB-IP databases (country and autonomous system) and writes `GeoCountry`, `GeoAsn` and `GeoOrg` at the end of the JSON line. A private address (LAN, cluster) gets empty strings. The country is not a Loki label on purpose, and the network could not be (too many values): Loki reads both back with `| json`.
3. **The databases** are the free DB-IP "lite" files (monthly, CC BY 4.0: the dashboard credits "IP Geolocation by DB-IP"). An init container of the Alloy pod downloads them at each start into `/var/lib/alloy-geoip` on the node (a host directory, so a failed download keeps the previous files and Alloy still starts). They are refreshed when Alloy restarts; nothing restarts it on a schedule, so a file can be a few months old: acceptable for a country, worth knowing.
4. **Noise.** The successful pushes of logs and metrics of every Alloy (`loki.core.phorge`, `prometheus.core.phorge`, status 204) were about 90% of the requests, and each logged line had to be pushed in turn: they are dropped in Alloy. A refused or failed push (401, 5xx) is kept.

## Reading it

```
{namespace="traefik"} |= "ClientHost" | json | GeoCountry != "FR" | GeoCountry != ""
{namespace="traefik"} |= "ClientHost" | json | DownstreamStatus >= 400
{namespace="traefik"} |= "ClientHost" | json | RequestHost = "git.phorge.fr" | ClientHost = "<address>"
```

The fields that are useful: `ClientHost`, `GeoCountry`, `GeoAsn`, `GeoOrg`, `RequestHost`, `RequestMethod`, `RequestPath`, `DownstreamStatus`, `Duration` (nanoseconds), `RouterName`, `ServiceName`, `request_User-Agent` (written `request_User_Agent` by `| json`), `TLSVersion`.

## Cap

Cap has no `/metrics` (only `/health`) and logs very little: its start and its errors, which are in Loki already (`{namespace="cap"}`). Its activity is read from the access log of `cap.phorge.fr`: a `POST .../challenge` is a challenge issued, a `POST .../redeem` a proof submitted (200 solved, 4xx/5xx refused). The check of the token by authentik (siteverify) stays inside the cluster and does not go through Traefik, so it is not counted. The "Cap" row of the dashboard shows these, the time to answer and the countries. The pod's CPU and memory are in the usual Kubernetes dashboards.

## Pitfalls met while building it

- Alloy's config goes through Helm's `tpl`: the Go template braces meant for Alloy must be written `{{ "{{" }}` and `{{ "}}" }}` in the HelmRelease, or the chart refuses to render.
- The lines read from the Kubernetes API end with a newline: the regex that appends the fields must accept it (`(\})\s*$`). A test on a file does not show it.
- `stage.drop` takes `source` as a comma-separated string, not a list.
- A template that reads a missing value writes `<no value>`: use `{{ with .x }}{{ . }}{{ end }}`.
- To test a pipeline without touching the real Alloy, run a throwaway Alloy pod (same image, `hostNetwork` and the service account `alloy` if it must read pods, the host directory mounted read-only) with the rendered block (`helm template`) and `loki.echo`. A broken reload leaves the old config running and the component `unhealthy` (Alloy UI, `/api/v0/web/components/loki.process.enrich` on the node's loopback); the mounted ConfigMap takes up to a minute to reach the pod.
- Loki rejects entries older than a week with a 400: an Alloy that restarts re-reads old lines and logs "timestamp too old", it is harmless.
- The two public addresses of `traefik-public` only show real client addresses since the DaemonSet and `externalTrafficPolicy: Local` (see `docs/authentik-hardening.md`, "The client address"). Lines from before show the address of a node.

## Personal data

The access log holds the client address, the host and path requested, the user agent, the country and the network, for the retention of Loki (30 days). See [gdpr.md](gdpr.md): it is in the table, and the decisions on retention apply to it too.

## What is left: `control` and `svc`

Their Alloy already pushes the pod logs of their Traefik to the Loki of core, so once Traefik writes the access log there, the lines arrive. Three things are missing:

1. **The real client address.** Same defect as core had: `traefik-public` there is `Cluster` with a Deployment, so the PROXY header of the edge HAProxy is ignored in the cases where the connection is forwarded between nodes (`api.phorge.fr`, `git.phorge.fr`). The fix is the one of core (DaemonSet and `Local`); do it with an availability probe and check that the L2 leader of the service has a local pod.
2. **The access log settings** in the Traefik patches of the two clusters (or move them to `base/controllers/traefik`).
3. **The enrichment.** The Alloy of these clusters (`base/controllers/alloy`) has no geoip stage and no databases yet. The block of core can be copied, and the same init container (DB-IP over the internet from each node). The `cluster` label already tells the clusters apart in the dashboard.
