---
status: accepted
date: 2026-11-01
decision-makers: l-nmch
---

# Evaluate ZITADEL against Authentik as the identity provider

## Context and problem statement

Authentik is the identity provider of Phorge ([0006](0006-authentik-as-code.md)). Three things push to look at another one:

* An API key is an identity composed by Crossplane ([Hangar#230](https://github.com/phorge-fr/Hangar/issues/230)). Authentik gives a token created for another user to its caller unless the caller is a superuser, and only `akadmin` is one. The Terraform provider has no resource for `POST /api/v3/core/users/service_account/`, the one call that creates an account and its token with a non-superuser ([Hangar#295](https://github.com/phorge-fr/Hangar/issues/295)).
* The rule of [Hangar#297](https://github.com/phorge-fr/Hangar/issues/297): `control` carries no full-admin secret, and a Crossplane provider mirrors its Terraform provider with nothing added.
* Authentik uses 1.27 GiB on `core` nodes that are already at 48 % to 72 % of their memory.

The question ([Hangar#304](https://github.com/phorge-fr/Hangar/issues/304)): can ZITADEL replace Authentik with every feature Phorge uses, and does it remove the blocker above?

## Decision drivers

* Every feature of the [sign-in layers](../reference/authentik-sign-in-layers.md) and every consumer keeps working.
* Least privilege: nobody holds more rights than the task needs, and no full-admin secret on `control`.
* The Crossplane provider is the public one, used as it is.
* Memory on the `core` nodes.
* Maintenance: what Phorge has to run and keep up to date itself.

## Considered options

* Keep Authentik and carry the upstream contribution of Hangar#295.
* Replace Authentik with ZITADEL, accepting the gaps listed below.
* Run both: ZITADEL for machine identities, Authentik for people (rejected at the outset: two identity providers, two sets of policies).

## How it was tested

A throwaway stack on one machine, nothing deployed: ZITADEL v4.20.0 (API, login v2 and PostgreSQL 17) behind Traefik v3.6 with TLS, a real Chromium driven by Playwright (with a virtual WebAuthn authenticator), Cap 3.1.17, Forgejo 13.0.5, Grafana 12.3.0, Incus 6.0.4 with a real `incusd`, `phorge-api`'s own `OIDCVerifier` code on a copy of the repository, and `provider-upjet-zitadel` v0.3.0 on a k3s cluster with Crossplane 2.4.3. No cluster of Phorge was touched.

## Decision outcome

Chosen option: **keep Authentik**, and create the identity and token of an API key with `provider-http` (a public Crossplane provider) calling `POST /api/v3/core/users/service_account/` with a narrow identity, instead of waiting for the upstream resource of Hangar#295. ZITADEL removes the blocker and goes further on rights, but it is not a 100 % replacement: two hardening features do not exist, a third (the alert on a sign-in outside France) loses its source, and three small services would be needed. The lighter footprint and the ready-made provider are the reasons to look at it again if Authentik keeps getting in the way.

### Results

Verdicts: **pass** (works as tested), **partial** (works with something added, named), **fail** (absent), **untested**.

#### Rights and API keys

| Feature | Verdict | What was measured |
| --- | --- | --- |
| Create the identity and key of an API key without being an administrator | pass | A machine user with the role `ORG_USER_MANAGER` on a dedicated organization (`phorge-keys`) created machine users, a client secret, a JSON key, and a personal access token. The same account got 403 or 404 on projects, applications, policies, identity providers, the other organizations, the instance settings, and its own membership |
| Escalation by the key manager | pass | `ORG_USER_MANAGER` can grant project roles to users of its organization, itself included, but only the roles the organization received through the project grant. With a grant that carries only `api-key`, an attempt to grant `phorge-platform-admins` failed with `Project.Role.NotFound`, and the manager could not widen the grant |
| Key authentication | pass | `client_credentials` with the secret gave a signed JWT (RS256, 12 h) with `sub`, an audience and the role `api-key`. Both the key and the personal access token (expiry date set) worked |
| Crossplane provider | pass | `MachineUser`, `Key` and `AccessToken` were created, ready and deleted with the manager's token, secrets included. After deletion the user no longer existed. `AccessToken` took several minutes to become ready |
| Configuration as code with a narrow identity | partial | `ORG_OWNER` of one organization created a `Project`, a `Role` and an `Oidc` application (client id and secret in the connection secret) through Crossplane. It cannot create Actions, change instance policies or SMTP, or touch another organization. An `ORG_OWNER` manages the users and grants of its whole organization (grants not tested), so the platform-admin role belongs in an organization of its own |
| No full-admin secret on `control` | partial | Everything per organization works without it. Instance settings (Actions v2 targets, SMTP, instance policies, login base URI) need `IAM_OWNER`, run once from outside `control` |
| Per-application access restriction | pass | A project with the role check enabled refused a user without a role (`Errors.User.GrantRequired`) and accepted one with it. The message shown to the person is "Unknown error occurred". Applications that need different audiences go in different projects |

#### Sign-in layers

| Feature | Verdict | What was measured |
| --- | --- | --- |
| Mandatory MFA, enrolment after the password | pass | `forceMfa` redirected to the enrolment (authenticator app or WebAuthn key). A wrong TOTP code was refused. WebAuthn as second factor worked with a virtual authenticator |
| Recovery codes | untested | The API exists (`/v2/users/{id}/recovery_codes`); the sign-in page was not driven with one |
| Unknown user looks like a known one | pass | With `ignoreUnknownUsernames` the page is identical to the one for a wrong password |
| Lock after 5 attempts | pass | The account was locked at the fifth wrong password, the right password was then refused with the same message. Anyone who knows a user name can lock the account of that user: ZITADEL has no per-address score to tell the attacker from the owner |
| Cap proof of work first | partial | The sign-in has no captcha stage. A Traefik `forwardAuth` gate in front of `/ui/v2/login` and `/oauth/v2/authorize` (about 50 lines of Python, tested) sent the browser to the Cap widget and let it through with a signed cookie after the siteverify. Phorge would run and maintain that gate. The old login at `/ui/login` is still served and must be blocked by the proxy |
| Per-address reputation score | fail | No equivalent. The Traefik rate limit works as before (60 requests in one second from one address: 21 passed, 39 got 429) |
| Session 12 h bound to ASN and country | partial | The session lasts 12 h by default and records the address and the user agent. There is no binding to ASN or country |
| Traefik rate limit | pass | Unchanged, independent of the provider |
| Device flow of the CLI | pass | Token with `email`, `groups` and a refresh token, after a consent screen. Needs a route at the proxy: ZITADEL announces `/device`, which leads to the old login, so Traefik redirects it to `/ui/v2/login/device` |
| Password reset by e-mail | pass | The instance SMTP delivered the reset message |
| Branding | partial | The label policy (colours, dark theme, logo, no watermark) is served to the login. The 348 lines of Authentik brand blueprint, including custom CSS, are not portable. Not checked on screen |

#### Monitoring and alerts

| Feature | Verdict | What was measured |
| --- | --- | --- |
| Prometheus metrics | partial | `/debug/metrics` works once the exporter is set to `prometheus` (the default `otel` has no scrape endpoint): Go runtime, process, database pool. No sign-in counters |
| Sign-in dashboard | partial | The logs of ZITADEL carry no user name and no address for a failed sign-in (the caller is the login client). Events are available as webhooks, but they carry neither an address nor a country. The addresses are in the sessions API and in the Traefik log. The dashboard has to be rebuilt on those |
| Discord alerts | partial | A webhook on events (`user.human.password.check.failed`, `user.locked`) delivered every event. The format is not Discord's, so a small forwarder is needed. "Sign-in outside France" and "superuser sign-in" have no source: the events carry no country, and there is no superuser |

#### Consumers

| Consumer | Verdict | What was measured |
| --- | --- | --- |
| `phorge-api` | partial | Its `OIDCVerifier`, unchanged, accepted the access token of a person: subject `user:alice@phorge.test`, group `phorge-platform-admins`. It needs an Action (see below) because the access token of ZITADEL has no `email`, `email_verified` or `groups`, and `OIDC_AUDIENCE` becomes the project id (it is in every token, the client id is not in a key's). A key's token has no email: the API must find the owner of a key another way |
| Incus | pass | A real `incusd` completed the device flow: `auth_user_method: oidc`, `auth_user_name: alice@phorge.test` (`oidc.claim: email`). The OpenFGA authorization was not part of the test |
| Forgejo | pass | With the `forgejo` claim from an Action, the administrator became administrator, and a user without the role was refused (Forgejo answers "Account is suspended") |
| Grafana | partial | Sign-in and role mapping from `groups` worked. A user without the role still signed in (the mapping gives it `None`, a valid role): the restriction belongs to the project role check above |
| Crossview, console | untested | Same pattern as Grafana (confidential client; the client created through Crossplane returned its id and secret) |

#### Footprint

Idle, then after 300 token requests: ZITADEL 108 then 114 MiB, login 120 MiB, PostgreSQL 90 then 97 MiB, which is about 320 MiB, against 1.27 GiB for Authentik on `core`. The figures are not like for like: the throwaway has almost no data and one user.

### Not equivalent

1. **No per-address reputation score.** Rate limit, the lock, mandatory MFA, and Cap remain.
2. **No session binding to ASN and country.**
3. **No alert on a sign-in outside France or a superuser sign-in**, and the dashboard has no failed sign-ins by address. They need a receiver that reads events and looks up the address of the session.

### What Phorge would run itself

* A claims target (Actions v2): `groups`, `email`, `email_verified` and `forgejo`, because ZITADEL does not put them in the token. It is instance level, so it needs `IAM_OWNER`, and the instance must allow a target in the cluster network (`HTTPCLIENT_DENYLIST`, which blocks private ranges by default).
* The Cap gate.
* The alert forwarder.
* Traefik routes for `/device`, the block of `/ui/login` and the gate.

### Consequences

* Good, because the key of Hangar#230 needs no superuser, no provider patch and no full-admin secret on `control`, and a provider released for everyone is enough.
* Good, because rights are finer: an organization is a boundary, a project grant bounds what a manager may assign, a project role check restricts an application.
* Good, because the stack is lighter at idle.
* Bad, because three features are lost and three small services are added.
* Bad, because the migration is large: about 1 000 lines of blueprints to rewrite (brand 348, hardening 210, `phorge-api` 138, Incus 81), seven integrations to rewire, and every person enrols MFA again (WebAuthn credentials cannot be exported).
* Bad, because the server is AGPL-3.0 (without change, nothing is owed), and the Crossplane provider is young: created in April 2026, v0.3.0, five contributors, on the Terraform provider 2.12.8.
* Bad, because the login v2 caches the login settings: a change of the login policy applied only after the login container restarted. How long the cache lasts is not known.

### Confirmation

The `ApiKey` composition of Hangar#230 creates a `Request` of `provider-http` and a connection secret; a test creates a key, authenticates with it, deletes it and checks that the token is gone.

#### API keys with provider-http

Tested on a throwaway Authentik 2026.8.5 with `provider-http` v1.0.15 on Crossplane 2.4.3:

* A `Request` with `CREATE` (POST to `service_account/`), `OBSERVE` (GET of the token) and `REMOVE` (DELETE of the token) created the account and its `app_password` token with the expiry date, and the `Request` became ready and synced. Several reconciles created one account only.
* `secretInjectionConfigs` put `.body.token` into a Secret with an owner reference, and the key was not left in plain text in the status of the `Request`. The Secret is deleted with the `Request`.
* The identity needs exactly `add_user`, `add_token`, `view_token` and `delete_token`. With it: a user without a role got 403 on listing users, on deleting or editing `akadmin`, on groups, providers and roles; adding a user to the superuser group was refused three ways; a token created for another user belongs to the caller (nothing is created for `akadmin`); the key of a token is never returned (`key` is null, `view_key` is 403).
* The role of Hangar#294 as written (`add_user`, `add_token`, `view_user`, `delete_user`) is too wide: `delete_user` is global and the identity **deleted `akadmin`** (204). It has to be replaced by `delete_token` and `view_token`.
* What the narrow identity can still do: create stray internal users without group or password, list the identifiers (not the keys) of every token, and delete any token, so a compromised `control` can break the keys and the outpost token, but it cannot take over an account or delete one.
* Deleting the `Request` deletes the token and leaves the service account, with no credential. The accounts are named after the key, so they do not collide, and an administrator removes the leftovers.
* **Update 2026-11-03**: the leftover is gone. Authentik has initial permissions (`authentik_rbac.initialpermissions`): the role of the identity gets `delete_user` and `view_user` on each user one of its members creates, and on nothing else. Tested on a throwaway: it reads and deletes the account it created (204, the token goes with it), cannot change it (403), and cannot see or delete `akadmin` (404). The `REMOVE` of the `Request` now deletes the user, so deleting an `ApiKey` leaves nothing in authentik.
* A custom `isRemovedCheck` that accepts any 200 stops the `REMOVE` from running: leave the default, which waits for the 404 of the token.

## Pros and cons of the options

### Keep Authentik and carry Hangar#295 (rejected for the API keys)

* Good, because every hardening feature and every consumer works today.
* Bad, because the API keys would wait for an upstream contribution and a release. `provider-http` avoids the wait and keeps `provider-authentik` identical to the Terraform provider.
* Bad, because the memory stays as it is.

### Replace Authentik with ZITADEL (not chosen)

* Good, because it removes the blocker and gives finer rights, see Consequences.
* Bad, because of the gaps and the services above, and the size of the migration.

## More information

* Not verified: passwordless sign-in with a passkey, sign-in with a recovery code, the break-glass procedure after losing the last `IAM_OWNER`, Incus authorization through OpenFGA, high availability and upgrades, backup and restore, the look of the branding.
* A search found two published advisories on the multi-factor check of the login v2 (CVE-2025-64103, fixed in 4.6.0 and 2.71.18, and CVE-2026-85056, a session reused before the second factor, fixed in 4.16.1). They were not read in detail. The tests ran on 4.20.0.
* The provider takes its token in the `access_token` key of the credentials; the `token` key is a path to a file.
