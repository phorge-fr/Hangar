---
type: reference
audience: maintainer looking up which layer protects the sign-in
verified: 2026-10-27
---

# Authentik sign-in: the layers

What a visitor meets, in order, on `auth.phorge.fr`. Everything is in `overlays/core/apps/` and applied by Flux, except the Cap site key.

| Layer | What it does | Where |
|---|---|---|
| Traefik rate limit | 5 requests/s per client address (burst 20) on the flow executor and the OAuth endpoints. The address is the real one (see "The client address" below). | `authentik/ratelimit.yml` |
| Reputation policy | Closes the sign-in flow to an address whose score falls to -5 (authentik lowers it by 1 at each failed sign-in and raises it by 1 at each success). Address only: the user is not known when the flow starts. The score of an address is the sum of its identifiers, each one kept between -5 and 5 by the tenant, so -5 is the lowest value a single user name can reach: a lower threshold would never trigger. | `blueprint-brand.yml` |
| Cap captcha | Proof of work, first step of the flow. Served by `cap.phorge.fr`, token checked inside the cluster. | `cap/`, `blueprint-brand.yml` |
| Identification and password | `pretend_user_exists`: an unknown name looks like a known one. The password stage gives up after 5 attempts. | `blueprint-brand.yml` |
| MFA | **Mandatory for everybody.** Asks for a passkey, a TOTP code or a recovery code; a user without a device enrols one right after the password (below). | `blueprint-brand.yml` |
| Session | Lasts 12 hours and is bound to the autonomous system and the country it was opened from. A private client address (LAN, cluster) has none, so those sessions are not bound. | `blueprint-brand.yml` |
| Alerts | A message in a Discord channel, through a webhook, on a sign-in from outside France (detection only, nothing is blocked), on a `suspicious_request`, on every sign-in of a superuser (severity alert), on every failed sign-in against one, and on the creation of a token or a user. It carries the action, the user name, the country and a request id, nothing else. | `blueprint-hardening.yml`, `secret-alerts.yml` |
| Tracking | Every event (sign-in, failure, logout, password change, suspicious request) is a JSON line in the logs of authentik, collected into Loki, and so is each start of the sign-in flow with the address, country, network and score. A dashboard reads them. | `grafana-dashboards/authentik-signins-dashboard.yml` |

The OIDC clients (Incus, Crossview, Phorge) use strict redirect URIs. Grafana and Forgejo are restricted to `phorge-platform-admins` (`blueprint-brand.yml`).

[Why it is built this way](../explanation/authentik-sign-in-hardening.md).
