---
type: how-to
audience: maintainer proving that a dashboard renders
verified: 2026-10-28
---

# Check a Grafana dashboard

A query returning data (Prometheus API, `/api/ds/query`) does not prove a dashboard renders: `/api/ds/query` returns labels as field metadata, while the browser builds the table columns (`Value #A` with several visible queries, `Value` with one). Take a screenshot and look at it.

## Recipe

1. Port-forward the Grafana service of the `kube-prometheus-stack` namespace. Read the admin password from the live secret into a shell variable; never print it.
2. Log in with `POST /login` to get the `grafana_session` cookie. It rotates about every ten minutes: log in again before each run and call `Network.clearBrowserCookies` before `Network.setCookie`, or the screenshot is the login page.
3. Start Chromium headless with `--headless=new --no-sandbox --disable-gpu --remote-debugging-port=<port> --remote-allow-origins='*'` and a profile directory it can write (the snap build cannot use `/tmp`). Without `--remote-allow-origins` the websocket gets a 403.
4. Use a Python virtual environment with `websocket-client` and drive the DevTools protocol: `Network.setCookie`, `Emulation.setDeviceMetricsOverride`, `Page.navigate` to `/d/<uid>?orgId=1&kiosk` (add `&from=now-1h&to=now`), wait about 18 seconds, `Page.captureScreenshot`.
5. Stop Chromium from a pid file, in a command that does not spawn it. `pkill -f` or `pgrep -f` with a pattern that also appears in the calling command line kills the calling shell.

## What it caught

- Stat panels with a range query show 0 when the data is younger than the step: use `instant: true`.
- A table-wide `noValue` also fills empty cells: override it per column.
- An axis flattened by one outlier series.
- A misleading red ratio (Longhorn actual size includes snapshots).
- The `organize` transformation orders by the original field names, then renames: `indexByName` with the renamed name is ignored.
