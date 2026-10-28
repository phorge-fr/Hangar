---
type: reference
audience: anyone querying the HTTP audit log in Loki
verified: 2026-10-27
---

# HTTP audit log: queries and fields

The log is written by Traefik and read in Loki; [how it works](../explanation/http-audit-log.md).

## Queries and fields

```logql
{namespace="traefik"} |= "ClientHost" | json | GeoCountry != "FR" | GeoCountry != ""
{namespace="traefik"} |= "ClientHost" | json | DownstreamStatus >= 400
{namespace="traefik"} |= "ClientHost" | json | RequestHost = "git.phorge.fr" | ClientHost = "<address>"
```

The fields that are useful: `ClientHost`, `GeoCountry`, `GeoAsn`, `GeoOrg`, `RequestHost`, `RequestMethod`, `RequestPath`, `DownstreamStatus`, `Duration` (nanoseconds), `RouterName`, `ServiceName`, `request_User-Agent` (written `request_User_Agent` by `| json`), `TLSVersion`.
