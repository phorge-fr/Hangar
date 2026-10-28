---
type: how-to
audience: maintainer locked out of the Authentik sign-in
verified: 2026-10-27
---

# Recover access to Authentik

Everything below runs on the `core` cluster. Start with the least invasive.

**A sign-in loop or a locked account.** Create a recovery key for the account (valid 60 minutes by default) and open the link it prints:

```bash
kubectl --context core -n authentik exec deploy/authentik-server -- ak create_recovery_key 60 akadmin
```

**The captcha does not load** (Cap down, key lost, widget broken). Unbind the stage from the flow so the sign-in works without it, fix Cap, then let Flux restore the binding (it comes back by itself at the next blueprint apply, or suspend `apps` and `flux-system` first to keep it off):

```bash
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.flows.models import FlowStageBinding
print(FlowStageBinding.objects.filter(target__slug='phorge-authentication-flow', stage__name='phorge-authentication-captcha').delete())"
```

If the Cap site key is gone (the Valkey volume was lost), create a new one: log in to the Cap API through `kubectl -n cap port-forward svc/cap 3100:3000` with `POST /auth/login {"admin_key": ...}` (the key is in the `cap` secret), `POST /server/keys` with `corsOrigins: ["https://auth.phorge.fr"]`, then replace the site key in `cap/cap.yml` (two ingress paths), in `blueprint-brand.yml` (the `public_key` URL and the `api_url`) and the secret in `authentik/secret-cap.yml`.

**An address is refused by the reputation policy.** Clear its score:

```bash
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.policies.reputation.models import Reputation
print(Reputation.objects.filter(score__lte=-5).delete())"
```

**Signed out all the time.** The session binding (ASN and country) may be too strict for a network that changes address. Set `network_binding` and `geoip_binding` to `no_binding` in `blueprint-brand.yml`.

**MFA locks an account out** (a lost device and no recovery code): the recovery key above signs the account in without the flow, then add a new device from the account settings. If the enrolment itself breaks for everybody, set `not_configured_action` back to `skip` in `blueprint-brand.yml` (a PR, or live with Flux suspended).

If authentik itself does not answer, `kubectl -n authentik rollout restart deploy/authentik-server deploy/authentik-worker` and look at `kubectl -n authentik logs deploy/authentik-server`.

## Related

- [Authentik sign-in hardening](../explanation/authentik-sign-in-hardening.md)
