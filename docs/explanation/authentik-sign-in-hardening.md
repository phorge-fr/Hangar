---
type: explanation
audience: maintainer who needs to understand the sign-in hardening
verified: 2026-10-27
---

# Authentik sign-in hardening

What stands between a visitor and `auth.phorge.fr`, where each piece lives, how the MFA works and how to get back in when something locks you out. Everything is in `overlays/core/apps/` and applied by Flux, except the Cap site key (see below).

The layers are listed in [Authentik sign-in: the layers](../reference/authentik-sign-in-layers.md).

## The client address

authentik only sees the address of the client if every hop passes it on. From outside, the edge HAProxy sends it in a PROXY protocol header (`send-proxy-v2`) and Traefik (`traefik-public`) believes that header only from `10.2.0.254`, the address of the HAProxy container. Until 2026-10-27 every sign-in was logged as `10.244.1.91`, with no country, because the Service was `externalTrafficPolicy: Cluster`: the node that answers for `10.2.0.11` (Cilium L2 announcement, here `core-wyse-02`, which had no Traefik pod) forwarded the connection to a pod on another node and rewrote its source to its own Cilium address. That address is not `10.2.0.254`, so Traefik dropped the header and used the rewritten source.

The fix (`overlays/<cluster>/controllers/traefik/traefik-public-patch.yml`, on `core`, `control` and `svc`): `externalTrafficPolicy: Local` keeps the source, and `traefik-public` runs as a DaemonSet (one pod per node, a new one ready before the old one stops) because with `Local` a node without a local pod drops the traffic: the first attempt with two replicas and `Local` cut the ingress for about 25 seconds, the L2 leader staying on the node without a pod. Check after any change to the Traefik release: `kubectl -n kube-system get lease cilium-l2announce-traefik-traefik-public` names the leader, and `kubectl -n traefik get pods -o wide` must show a pod on that node.

What the address is now: a visitor from outside, the real address; a client of the LAN, its own LAN address; a pod that calls `auth.phorge.fr` through the public address (Grafana, Forgejo), the address of the site, because it leaves the cluster by its node. Private addresses have no country or network, so they are never bound to a session and never trigger the alert from outside France.

## Alerts and tracking

**The webhook.** `secret-alerts.yml` (SOPS) holds the URL, authentik reads it through the `ALERT_WEBHOOK_URL` variable (`authentik.yml`) and the blueprint uses it with `!Env`. It is the Discord channel of the Alertmanager alerts today; to send the sign-in alerts to another channel, replace the URL in that secret. The transport has `send_once`, because authentik creates one notification per member of the destination group and the channel must get one message. The message is built by the mapping `phorge-alert-discord` (`blueprint-hardening.yml`), which keeps the address, the e-mail and the browser out of Discord on purpose.

**The logs.** authentik writes each event as a JSON line (`"event": "Created Event"`) on the standard output of the server, and Alloy sends every pod log to Loki. The fields (`action`, `client_ip`, `user_username`, `context_geo_country`, `request_id`) are not Loki labels, they are extracted at query time with `| json`. In Grafana, Explore, Loki:

```logql
{namespace="authentik"} |= "Created Event" | json | action="login_failed"
{namespace="authentik"} |= "Created Event" | json | action="login" | context_geo_country != "FR"
{namespace="authentik"} |= "Created Event" | json | request_id="<id from the Discord message>"
```

Two kinds of line carry the reputation. authentik logs `Updated score` (`for_ip`, `for_user`, `amount` = the new score of that identifier) at each failed or successful sign-in. The policy `phorge-authentication-audit` logs `Sign-in flow started` (`client_ip`, `country`, `continent`, `asn`, `as_org`, `reputation` = the score of the address before the attempt) each time the flow starts, including for a visitor who stops at the captcha, who raises no event. It always returns False and the flow passes when any of its policies passes, so it never decides anything: keep the flow in mode `any`.

```logql
{namespace="authentik"} |= "Sign-in flow started" | json | country != "FR"
{namespace="authentik"} |= "Updated score" | json | amount < 0
{namespace="authentik"} |= "Sign-in flow started" | json | reputation <= -3
```

The dashboard "Authentik sign-ins" (folder Core) shows the counts over 24 hours, the events by action, the addresses with the most failures and the list of events. Events created by hand from `ak shell` are not in Loki, since that output is not the one of the container.

Loki keeps the lines for 30 days and the authentik database keeps the events for 365 days. Neither value was chosen against a rule: see [the personal data inventory](../reference/gdpr-personal-data.md), which also lists the personal data these logs hold.

**A blueprint in `error` right after a deploy.** Changing a blueprint and the variable it reads in the same change makes the worker that is still running apply the new blueprint before it has the variable: the instance goes to `error` and nothing of the new content exists. `blueprints_discovery` applies it again every hour (at :32) and fixes it by itself; to do it at once:

```bash
kubectl --context core -n authentik exec deploy/authentik-worker -- ak shell -c "
from authentik.blueprints.models import BlueprintInstance
from authentik.blueprints.v1.tasks import apply_blueprint
apply_blueprint.send(str(BlueprintInstance.objects.get(name='phorge-hardening').pk))"
```

## MFA

MFA is mandatory for every account: the validation stage of the flow is `not_configured_action: configure`. A user who has no device is sent, after the password, to a choice between a passkey (WebAuthn) and a TOTP app, enrols it, and is signed in. The recovery codes (static) are accepted at sign-in but are not offered as the first device (someone could stop at a list of codes); create them afterwards. This was checked end to end with a throwaway user before it was turned on: password, choice of TOTP, code, signed in.

To enrol an account, see [Enrol MFA for an account](../how-to/enrol-mfa-for-an-account.md).

A user created latergoes through the same enrolment at the first sign-in. The accounts that do not use the flow (service accounts, API tokens) are not concerned.

## Not done, and why

- **Stronger password rules.** The default password-change flow has its own policy (8 characters, zxcvbn) and its blueprint is applied again by authentik, so a stricter policy would be undone. It becomes worthwhile with an own password-change or enrolment flow.
- **Admin console restricted by address.** The administrators come from an address that changes; an allow-list would lock them out. The console is protected by the sign-in flow above, the MFA and `phorge-platform-admins`.
- **Account creation with a verified e-mail.** There is no enrolment flow, so no public sign-up. When there is one, it needs the verification stage and the `Phorge email` mapping of `blueprint-phorge-api.yml` (it returns `email_verified: True` for everybody today) changed together.

## Related

- [Recover access to Authentik](../how-to/recover-access-to-authentik.md)
