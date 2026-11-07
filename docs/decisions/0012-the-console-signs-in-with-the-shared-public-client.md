---
status: accepted
date: 2026-11-07
decision-makers: l-nmch
---

# The console signs in with the shared public client

## Context and problem statement

[0009](0009-build-the-frontend-with-sveltekit.md) gave the console its own confidential OIDC client in Authentik, instead of the public client the command line uses. That client was built (Hangar#346) and then found not to work with the API: Authentik puts the slug of the application in the issuer of a token (`.../application/o/<slug>/`), the API checks one issuer, and a token of the console client carries another one than the shared client's. Making the API accept two issuers is a change of its own.

Which client does the console sign in with?

This replaces the choice of the client in 0009; the rest of 0009 stands.

## Decision drivers

* The API accepts the tokens of the shared client today and needs no change for them.
* The tokens stay on the server of the console, never in the browser.
* A credential should be limited to what its holder needs, and be revocable alone.

## Considered options

* A confidential client of its own for the console, with the API accepting a second issuer.
* The shared public client, with PKCE and no secret.

## Decision outcome

Chosen option: "the shared public client", because the API accepts its tokens as they are and the console can ship without waiting for a change to the API.

* The console uses the authorization code flow with PKCE (`S256`), `state` and `nonce`, and sends no secret (`OIDC_CLIENT_SECRET` stays unset).
* The provider `Phorge OAuth` lists the callback, the sign-out address and the development address of the console as strict redirect URIs.
* The provider `Console OAuth`, its application and its secret are removed.

### Consequences

* Good, because the API, its audience and its issuer are unchanged.
* Good, because there is no secret to create, copy to `svc` and rotate.
* Bad, because the console cannot prove to Authentik that it is the console: a code obtained for a registered redirect address is exchanged with the PKCE verifier alone.
* Bad, because one client now serves the command line (device code), the API keys (`client_credentials`) and the console, so their rights add up and cannot be revoked or audited apart.
* Neutral: the refresh token of the provider is valid 30 days and its renewal threshold is `seconds=0`, which authentik documents as renewing the refresh token at each use. That rotation is set, but has not been observed yet.

### Confirmation

The sign-in of the console is tested end to end when the console is deployed ([Hangar#347](https://github.com/phorge-fr/Hangar/issues/347)); that test also observes whether the refresh token changes at each use. If the rights of the shared client have to be separated, the option "a confidential client of its own" comes back, with [phorge-fr/phorge-api#64](https://github.com/phorge-fr/phorge-api/issues/64) (a second issuer) reopened.

## Pros and cons of the options

### A confidential client of its own

* Good, because the console proves who it is and its rights are separate from the command line's.
* Bad, because it needs the API to accept a second issuer, and a secret to create and keep in step on two clusters.

### The shared public client

* Good, because nothing changes in the API.
* Bad, because of the consequences above.

## More information

* [Hangar#350](https://github.com/phorge-fr/Hangar/issues/350), [phorge-fr/phorge-console#23](https://github.com/phorge-fr/phorge-console/issues/23).
