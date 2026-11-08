---
type: explanation
audience: maintainer who decides how identities and rights flow between the console, the API, Authentik, OpenFGA and Incus
verified: 2026-11-08
---

# Audit of the management of rights

This page audits how a person is identified and what they may do, from the console to Incus, against the documentation and the standards of each tool. It was written before the terminal ([phorge-fr/phorge-api#31](https://github.com/phorge-fr/phorge-api/issues/31)) and the self-service work add more to it. It ends with a proposal for how the API carries the identity of a user to Incus. The exchange was measured and the decision is recorded in [0013](../decisions/0013-the-api-exchanges-the-token-of-a-user-for-incus.md); nothing here is deployed.

## How it works today

Four systems take part, and each does one job.

| System | Job | What it holds |
| --- | --- | --- |
| Authentik | Says who a person is, with a signed token | Accounts, two OIDC applications (`phorge` and `incus`) |
| OpenFGA store of the API | Says what a person may do in the API | Roles on tenants, the scopes of API keys, with an expiry |
| OpenFGA store of Incus | Says what a person may do in Incus | Roles on Incus projects, `can_exec` on instances |
| The API and Incus | Check the token, then ask their store | Nothing: they trust the token and the store |

A person signs in to the console with the shared public client of the `phorge` application. The console keeps the tokens on its server and calls the API with them. The API checks the signature, the issuer and the audience, takes the user from the email claim, and asks its store. Incus does the same with its own application and its own store, and its default answer for a person who is not in OpenFGA is refusal.

## What was checked

Each statement of a finding comes from one of these. Where a point is a measure on this platform, it says so.

* The Incus documentation on [authentication](https://linuxcontainers.org/incus/docs/main/authentication/) and the code of its token check.
* The Authentik documentation of [token exchange](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/token_exchange/), and the version that runs here (2026.8.5, read from the cluster).
* [RFC 9068](https://rfc-editor.org/rfc/rfc9068) (JWT access tokens), [RFC 8693](https://datatracker.ietf.org/doc/html/rfc8693) (token exchange) and [section 5.7 of OpenID Connect Core](https://openid.net/specs/openid-connect-core-1_0.html) (stable identifiers).
* The OpenFGA documentation of [best practices for tuples](https://openfga.dev/docs/getting-started/tuples-api-best-practices) and [immutable models](https://openfga.dev/docs/getting-started/immutable-models), and the deployed version (1.22.1, with a pre-shared key).

## Findings

### 1. Sharing one client or one audience across services (high, in the proposal)

The idea of one OIDC application for the console, the API and Incus is the cleanest on paper and is wrong for three reasons.

* Incus says that its OIDC client ID should not be shared with other applications.
* A token for one service must not be accepted by another. RFC 9068 requires the resource server to check that the audience of the token names itself, and requires the authorization server to use a distinct audience for each resource. One audience for several services lets a stolen token work on all of them, and the number of services only grows.
* Incus checks the issuer and the signature of the token, and checks the audience only if `oidc.audience` is set. The issuer of the console token is the `phorge` application and Incus expects the `incus` one, so Incus refuses it today. This comes from reading the code, and is to be confirmed by a measure.

The same holds for any service added later, S3 for instance: one application per service, unless a service has to receive a token that the API relays for a user.

### 2. People are identified by email (medium, existing)

The tuples of OpenFGA, the claim that Incus reads (`oidc.claim: email`) and the API all key a person by email. OpenID Connect Core says that `iss` and `sub` together are the only stable identifier, that an issuer may reuse an email for another person, that an email may change, and that `email` and `preferred_username` must not be used as unique identifiers. The OpenFGA best-practice page also says not to put identifiers that include personal data in tuples.

The platform lowers the risk today: accounts are made by an administrator, nobody enrols alone, and the blueprint says so. It would become real if a person could change their email (they would lose their rights, or a reused address would inherit them), and the self-service work raises the number of accounts.

Users cannot change their email in Authentik today (`default_user_change_email` is false, read on 2026-11-08), which is what keeps this safe. KYC, metering and billing will need them to change it, and that must not be opened before people are identified by `sub` (or another immutable identifier) in the tuples, the API and Incus. The move is large (every tuple, the Incus claim, the invitations by email, the console) and is tracked in [Hangar#423](https://github.com/phorge-fr/Hangar/issues/423), to be decided with the KYC and billing design. Until then the setting stays closed.

### 3. The Phorge client does three jobs (medium, known)

[Decision 0012](../decisions/0012-the-console-signs-in-with-the-shared-public-client.md) already says that the command line, the API keys and the console share one public client, so their rights add up and cannot be revoked apart. The API keys use `client_credentials` with a user name and an application password, which is the mode Authentik documents for machine accounts but not the client authentication of RFC 6749. It is acceptable, and it ties the keys to Authentik.

### 4. The API does not pin the OpenFGA model (medium)

The OpenFGA documentation strongly recommends giving the model ID in checks, list queries and writes, for performance and for stable behaviour until the model is switched on purpose. The API does not, so it uses the latest model, and a model written early takes effect at once. This already happened when a model without the new relations was deployed (Hangar#393). Pinning the ID, set in the deployment from the status of the model, removes that risk.

### 5. One setting stands between every account and full access to Incus (medium)

Incus gives full access to any person that its OIDC provider authenticates, unless an authorization method is set. Here `authorization.client.oidc: openfga` is that method. If it is lost, every account of Authentik is an administrator of Incus. A group in front of the Incus application (`iaas-users`, one member) used to be a second lock. It also kept self-service users out of Incus and out of the token exchange, and it is removed (Hangar#410): the Ansible run now fails when the setting is not present (Ansible#71), which puts the protection where the risk is.

### 6. Two OpenFGA stores are right (keep)

The nodes of Incus hold the key of their store, and `incus config show` prints it, so root on a node can write tuples there. If the rights of the API shared that store, a node taken over could grant anyone anything in the API. Keeping two stores keeps the two zones apart. The models also have different owners: Incus fixes its own, the API versions its own.

### 7. What is sound

* The API checks the signature (RS256 and ES256 only), the issuer, the audience and a verified email, and answers one `401` whatever is wrong.
* An API key never exceeds its creator, and its tuples carry an expiry that OpenFGA evaluates, so a revoked or expired key is refused even if its token is still valid.
* A tenant a person cannot see answers like one that does not exist.
* The OpenFGA deployed here uses a pre-shared key, so the audience flaw of OpenFGA 1.17 and earlier in OIDC mode (CVE-2026-55689) does not apply, and the version is past the fix anyway.
* No rule depends on the console alone: the API decides.

## Proposal: carry the user's identity to Incus with a token exchange

The terminal needs the API to speak to Incus as the user, without holding a certificate that could open every VM of every tenant. The standard way is an exchange of tokens (RFC 8693): the API gives Authentik the token of the user and asks for a token for another audience.

Authentik 2026.8 supports it. With an `audience`, the new token takes the issuer, the signing key and the client ID of the target provider, so it is a token of the `incus` application that Incus accepts as it is. The target provider must list the exchanging provider as federated, the policies of the target application still apply to the user, and the email claim comes from the scope mappings of the target provider.

What this gives:

* The Incus client is not shared, and the console token is not valid on Incus. Findings 1 and 5 are satisfied.
* The rule for later services is the same: a service that receives a relayed identity gets its own application, listed as a target. Authentik takes one audience per exchange.
* Nothing changes for the CLI and the Incus interface.

Measured on the real Authentik and Incus on 2026-11-08, with a throwaway service account that had an email, and with the exchange enabled by a temporary change of two blueprints (undone afterwards):

* A token of the `phorge` application presented to Incus is refused with `401`, `issuer does not match`. The token of the console would be too.
* The exchange works from the `Phorge OAuth` client, which is public: no secret is needed. The new token has the issuer of the `incus` application, the Incus client ID as audience, the email, one hour of validity, and no `act` claim (impersonation).
* A person outside the group that was bound to the Incus application, `iaas-users`, was refused the exchange (`invalid_grant`), and one inside got the token. The group is removed, so any account gets the token and OpenFGA decides.
* Incus accepts the exchanged token and names the person by their email (`auth: trusted`, method `oidc`). With no right in OpenFGA it lists no project.
* With `can_exec` given to that person on one instance, an exec on that instance is accepted (`202`), and an exec on another instance of the same project is refused (`403`, `does not have entitlement "can_exec"`). Before the tuple, the exec on the first one is `403` too.
* An interactive terminal works with that token: the input is run and its output comes back, and the window can be resized through the control socket. The websocket handshakes need the same `Authorization` header as the request that created the operation.
* **Removing `can_exec` while a terminal is open does not close it.** The session was still open 92 seconds after the tuple was removed, as seen from the node. A new exec is refused at once, but the running one is not. The statement that Incus rechecks a running session every 30 seconds does not hold here, so the API has to do it.

Not measured: the exchange for a real person (the claims should be the same), the cost of one exchange, and what a person with no tuple at all can do in Incus once the group is gone (it listed no project with the token of a person outside any tuple).

Consequence for the terminal: the relay of the API, not Incus, ends a session. It rechecks the right of the person in its own store at a fixed interval and closes the session when it is gone, and it enforces a maximum duration and an idle timeout. The exchanged token is requested when a terminal opens, kept in memory for that session, never logged and never stored.

## Options set aside

| Option | Why not |
| --- | --- |
| One application for all services | Breaks the Incus rule on its client ID and the audience separation (finding 1) |
| The console signs in through the Incus application, the API accepts two issuers | Shares the Incus client ID too |
| A certificate held by the API | A compromised API reaches every VM of every tenant |
| One OpenFGA store | A compromised node could write the rights of the API (finding 6) |

## What to do, in order

1. Done: the decision record 0013 is accepted, and the exchange and the relay are built and measured on the platform (phorge-fr/phorge-api#31).
2. Add the check of the Incus authorization setting to the Ansible run (done, Ansible#71).
3. Pin the OpenFGA model ID in the API.
4. Move from email to `sub` before users may change their email, as its own piece of work (Hangar#423).
