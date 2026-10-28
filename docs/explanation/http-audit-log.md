---
type: explanation
audience: maintainer who reads or changes the HTTP audit log
verified: 2026-10-27
---

# The HTTP audit log

Every HTTP request that reaches a cluster through Traefik is written as a JSON line, collected into Loki, enriched with the country and the network of the client, and read in Grafana by the dashboard "HTTP audit (Traefik)" (folder Core, uid `http-audit`). It answers: who comes (address, country, network, user agent), to whom (host, service), and why a request failed.

State: **the three clusters** (`core`, `control`, `svc`). The dashboard has a Cluster variable.

## How it works

1. **Traefik** (`traefik-public` and `traefik-local` of every cluster, `base/controllers/traefik/traefik.yml`) writes the access log in JSON on its standard output. Alloy already ships every pod log of every cluster to the Loki of core, so nothing else collects it. Only the `User-Agent` header is kept (never `Authorization` or `Cookie`), the `Referer` is dropped and so is the query string of the path (`queryParameters.defaultMode: drop`, Traefik 3.7.3+): it can hold an OAuth code, a state or a device code.
2. **Alloy** (`loki.process "enrich"`, in `base/controllers/alloy/alloy.yml` for `control` and `svc`, and in `overlays/core/controllers/alloy/alloy.yml` for `core`, which is a separate copy that also has the drop stage below) takes the lines of the namespace `traefik` that carry a `ClientHost`, looks the address up in two DB-IP databases (country and autonomous system) and writes `GeoCountry`, `GeoAsn` and `GeoOrg` at the end of the JSON line. A private address (LAN, cluster) gets empty strings. The country is not a Loki label on purpose, and the network could not be (too many values): Loki reads both back with `| json`.
3. **The databases** are the free DB-IP "lite" files (monthly, CC BY 4.0: the dashboard credits "IP Geolocation by DB-IP"). An init container of the Alloy pod downloads them at each start into `/var/lib/alloy-geoip` on the node (a host directory, so a failed download keeps the previous files and Alloy still starts). They are refreshed when Alloy restarts; nothing restarts it on a schedule, so a file can be a few months old: acceptable for a country, worth knowing.
4. **Noise.** The successful pushes of logs and metrics of every Alloy (`loki.core.phorge`, `prometheus.core.phorge`, status 204) were about 90% of the requests, and each logged line had to be pushed in turn: they are dropped in Alloy. A refused or failed push (401, 5xx) is kept.

## Cap

Cap has no `/metrics` (only `/health`) and logs very little: its start and its errors, which are in Loki already (`{namespace="cap"}`). Its activity is read from the access log of `cap.phorge.fr`: a `POST .../challenge` is a challenge issued, a `POST .../redeem` a proof submitted (200 solved, 4xx/5xx refused). The check of the token by authentik (siteverify) stays inside the cluster and does not go through Traefik, so it is not counted. The "Cap" row of the dashboard shows these, the time to answer and the countries. The pod's CPU and memory are in the usual Kubernetes dashboards.

## Personal data

The access log holds the client address, the host and path requested, the user agent, the country and the network, for the retention of Loki (30 days). See [the personal data inventory](../reference/gdpr-personal-data.md): it is in the table, and the decisions on retention apply to it too.

## The three clusters

`control` (`api.phorge.fr`) and `svc` (`git.phorge.fr`) had the client address defect that `core` had: `traefik-public` was a Deployment with `externalTrafficPolicy: Cluster`, so the PROXY header of the edge HAProxy was ignored whenever the connection was forwarded between nodes. They now run it as a DaemonSet with `Local`, like `core` (see [the client address](authentik-sign-in-hardening.md#the-client-address)). Changing it cut each public ingress for 13 to 14 seconds (4 and 5 failed probes out of 140 and 155), because the Deployment pods stop before the DaemonSet pods are ready: **pre-pull the Traefik image on every node first** (the Raspberry Pi leader of `control` did not have it), and check that the L2 leader has a local pod afterwards.

The Alloy of these clusters has the same enrichment as `core`, minus the drop of the machine pushes (the pushes of logs and metrics only go through the Traefik of `core`). The databases are downloaded by the init container from each node over the internet, and an old line replayed at a restart is refused by Loki ("entry too far behind"), which is harmless.

The two public addresses of `traefik-public` only show real client addresses since the DaemonSet and `externalTrafficPolicy: Local` (see [the client address](authentik-sign-in-hardening.md#the-client-address)). Lines from before show the address of a node.

## Related

- [Fields and queries](../reference/http-audit-fields.md)
- [Test an Alloy pipeline](../how-to/test-an-alloy-pipeline.md)
