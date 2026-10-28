---
type: how-to
audience: maintainer whose Network dashboard went empty
verified: 2026-10-28
---

# Fix an empty router dashboard

MKTXP runs on `core` (`overlays/core/apps/mktxp/`); its dashboard is `grafana-dashboards/mktxp-dashboard.yml` (Grafana folder "Network"). It reads the router through the RouterOS API over TLS, checked against the router CA stored in a ConfigMap, as a read-only RouterOS user allowed only from the `core` nodes.

## What is manual, and must stay in sync

- The router's `api-ssl` service is set **by hand**: certificate, TLS 1.2, allowed addresses. It is not in OpenTofu because the provider cannot delete a service. After a router reset, the reset runbook of `phorge-fr/Network` (`docs/runbook-reset.md`, "API service (not under OpenTofu)") gives the command.
- The monitoring user's password lives in **two places that must stay identical**: the gitignored `.env` of `phorge-fr/Network` and the SOPS secret `mktxp-credentials` here. Rotate both.
- Users and groups are generic in Network (variables, `users.tf`); the monitoring user is one entry. Keep variables and logic general, never tool-specific.

## If the dashboard goes empty, check in this order

1. `up{job="mktxp"}`.
2. The `api-ssl-from-core` input firewall rule, and its position above the factory drop.
3. The `api-ssl` service (disabled, certificate, address).
4. The user (disabled, allowed address).
5. The password in both places.

## Quirks

The image has no ENTRYPOINT, so container `args` need `command: [mktxp]`. The read-only root filesystem makes MKTXP log "Please update mktxp.conf" at start (harmless). The default scrape class adds `cluster="core"` to the router series. Dashboard tables showed Kubernetes labels until excluded in their `organize` transform.
