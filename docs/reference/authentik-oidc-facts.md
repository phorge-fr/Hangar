---
type: reference
audience: developer working on the OIDC application of the Phorge API
verified: 2026-10-28
---

# Authentik OIDC facts

For the OIDC application used by the Phorge API (issuer `https://auth.phorge.fr/application/o/phorge/`).

- The default scope mapping `scope-email` returns `"email_verified": false` for everybody. The Phorge API refuses unverified emails, so `blueprint-phorge-api.yml` carries its own mapping that returns true, justified by accounts being created by an administrator with no self-enrollment. Revisit before ever opening an enrollment flow.
- **Device flow polling** (`/application/o/token/`): send `--data-urlencode "device_code=..."`. The code is 128 random characters including `&`, `+`, `%` and `*`; `curl -d` leaves them raw and Authentik then answers `invalid_grant` forever instead of `authorization_pending`. Approval needs both the login and the consent click; check the `authorize_application` events.
- **Inspect** with `kubectl -n authentik exec deploy/authentik-server -- ak shell -c "..."` (Django ORM: `OAuth2Provider`, `DeviceToken`, `Event`, `BlueprintInstance`). Output is mixed with import logs: grep a prefix. Events created from `ak shell` do not reach Loki.
- Test blueprints live with the procedure of [Test a Flux change live](../how-to/test-a-flux-change-live.md).
