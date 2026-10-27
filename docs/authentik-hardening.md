# Authentik sign-in hardening

What stands between a visitor and `auth.phorge.fr`, where each piece lives, how to turn MFA on and how to get back in when something locks you out. Everything is in `overlays/core/apps/` and applied by Flux, except the Cap site key (see below).

## Layers, in the order a sign-in meets them

| Layer | What it does | Where |
|---|---|---|
| Traefik rate limit | 5 requests/s per client address (burst 20) on the flow executor and the OAuth endpoints. The address is the real one for visitors from outside; the LAN and the cluster share one. | `authentik/ratelimit.yml` |
| Reputation policy | Closes the sign-in flow to an address whose score falls to -10 (authentik lowers it at each failed sign-in). Address only: the user is not known when the flow starts. | `blueprint-brand.yml` |
| Cap captcha | Proof of work, first step of the flow. Served by `cap.phorge.fr`, token checked inside the cluster. | `cap/`, `blueprint-brand.yml` |
| Identification and password | `pretend_user_exists`: an unknown name looks like a known one. The password stage gives up after 5 attempts. | `blueprint-brand.yml` |
| MFA validation | Asks for a passkey, a TOTP code or a recovery code **when the user has a device**. Not mandatory yet (below). | `blueprint-brand.yml` |
| Session | Lasts 12 hours and is bound to the autonomous system and the country it was opened from. A private client address (LAN, cluster) has none, so those sessions are not bound. | `blueprint-brand.yml` |
| Alerts | A message in a Discord channel, through a webhook, on a sign-in from outside France (detection only, nothing is blocked) and on a `suspicious_request`. It carries the action, the user name, the country and a request id, nothing else. | `blueprint-hardening.yml`, `secret-alerts.yml` |
| Tracking | Every event (sign-in, failure, logout, password change, suspicious request) is a JSON line in the logs of authentik, collected into Loki. A dashboard reads them. | `grafana-dashboards/authentik-signins-dashboard.yml` |

The OIDC clients (Incus, Crossview, Phorge) use strict redirect URIs. Grafana and Forgejo are restricted to `phorge-platform-admins` (`blueprint-brand.yml`).

## Alerts and tracking

**The webhook.** `secret-alerts.yml` (SOPS) holds the URL, authentik reads it through the `ALERT_WEBHOOK_URL` variable (`authentik.yml`) and the blueprint uses it with `!Env`. It is the Discord channel of the Alertmanager alerts today; to send the sign-in alerts to another channel, replace the URL in that secret. The transport has `send_once`, because authentik creates one notification per member of the destination group and the channel must get one message. The message is built by the mapping `phorge-alert-discord` (`blueprint-hardening.yml`), which keeps the address, the e-mail and the browser out of Discord on purpose.

**The logs.** authentik writes each event as a JSON line (`"event": "Created Event"`) on the standard output of the server, and Alloy sends every pod log to Loki. The fields (`action`, `client_ip`, `user_username`, `context_geo_country`, `request_id`) are not Loki labels, they are extracted at query time with `| json`. In Grafana, Explore, Loki:

```
{namespace="authentik"} |= "Created Event" | json | action="login_failed"
{namespace="authentik"} |= "Created Event" | json | action="login" | context_geo_country != "FR"
{namespace="authentik"} |= "Created Event" | json | request_id="<id from the Discord message>"
```

The dashboard "Authentik sign-ins" (folder Core) shows the counts over 24 hours, the events by action, the addresses with the most failures and the list of events. Events created by hand from `ak shell` are not in Loki, since that output is not the one of the container.

Loki keeps the lines for 30 days and the authentik database keeps the events for 365 days. Neither value was chosen against a rule: see [gdpr.md](gdpr.md), which also lists the personal data these logs hold.

**A blueprint in `error` right after a deploy.** Changing a blueprint and the variable it reads in the same change makes the worker that is still running apply the new blueprint before it has the variable: the instance goes to `error` and nothing of the new content exists. `blueprints_discovery` applies it again every hour (at :32) and fixes it by itself; to do it at once:

```
kubectl --context core -n authentik exec deploy/authentik-worker -- ak shell -c "
from authentik.blueprints.models import BlueprintInstance
from authentik.blueprints.v1.tasks import apply_blueprint
apply_blueprint.send(str(BlueprintInstance.objects.get(name='phorge-hardening').pk))"
```

## Turning MFA on

MFA is validated but not required, because nobody can be forced to enrol before having a device.

1. Sign in, open `https://auth.phorge.fr/if/user/`, Settings, MFA Devices and enrol two supports: a passkey (WebAuthn) on two devices, or a passkey and a TOTP app. Also create the static recovery codes and keep them offline.
2. Sign out and in again to check that the second factor is asked.
3. In `blueprint-brand.yml`, set `not_configured_action: configure` on `phorge-authentication-mfa`, open a PR and merge. A user without a device is then sent to one of the setup flows already listed in `configuration_stages`.

Do step 3 only after step 2 worked for every account that must still sign in.

## Getting back in

Everything below runs on the `core` cluster. Start with the least invasive.

**A sign-in loop or a locked account.** Create a recovery key for the account (valid 60 minutes by default) and open the link it prints:

```
kubectl --context core -n authentik exec deploy/authentik-server -- ak create_recovery_key 60 akadmin
```

**The captcha does not load** (Cap down, key lost, widget broken). Unbind the stage from the flow so the sign-in works without it, fix Cap, then let Flux restore the binding (it comes back by itself at the next blueprint apply, or suspend `apps` and `flux-system` first to keep it off):

```
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.flows.models import FlowStageBinding
print(FlowStageBinding.objects.filter(target__slug='phorge-authentication-flow', stage__name='phorge-authentication-captcha').delete())"
```

If the Cap site key is gone (the Valkey volume was lost), create a new one: log in to the Cap API through `kubectl -n cap port-forward svc/cap 3100:3000` with `POST /auth/login {"admin_key": ...}` (the key is in the `cap` secret), `POST /server/keys` with `corsOrigins: ["https://auth.phorge.fr"]`, then replace the site key in `cap/cap.yml` (two ingress paths), in `blueprint-brand.yml` (the `public_key` URL and the `api_url`) and the secret in `authentik/secret-cap.yml`.

**An address is refused by the reputation policy.** Clear its score:

```
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.policies.reputation.models import Reputation
print(Reputation.objects.filter(score__lte=-10).delete())"
```

**Signed out all the time.** The session binding (ASN and country) may be too strict for a network that changes address. Set `network_binding` and `geoip_binding` to `no_binding` in `blueprint-brand.yml`.

**MFA locks an account out** after step 3 of the previous section: set `not_configured_action` back to `skip` through the same blueprint, or use the recovery key above to reach the account settings and enrol a device.

If authentik itself does not answer, `kubectl -n authentik rollout restart deploy/authentik-server deploy/authentik-worker` and look at `kubectl -n authentik logs deploy/authentik-server`.

## Not done, and why

- **Stronger password rules.** The default password-change flow has its own policy (8 characters, zxcvbn) and its blueprint is applied again by authentik, so a stricter policy would be undone. It becomes worthwhile with an own password-change or enrolment flow.
- **Admin console restricted by address.** The administrators come from an address that changes; an allow-list would lock them out. The console is protected by the sign-in flow above, the MFA once required and `phorge-platform-admins`.
- **Account creation with a verified e-mail.** There is no enrolment flow, so no public sign-up. When there is one, it needs the verification stage and the `Phorge email` mapping of `blueprint-phorge-api.yml` (it returns `email_verified: True` for everybody today) changed together.
