---
status: proposed
date: 2026-11-08
decision-makers: l-nmch
---

# The API exchanges the token of a user for a token of Incus

## Context and problem statement

A terminal on an instance is the exec of Incus. The API must open it as the person who asks, so that Incus decides what that person may do, and the API holds no Incus credential: a certificate able to exec would reach every VM of every tenant. Incus accepts only tokens of its own OIDC application, and the token of the console comes from the `phorge` application (measured: `401`, issuer does not match).

How does the identity of the user get from the API to Incus?

## Decision drivers

* The Incus documentation says its OIDC client ID should not be shared with other applications.
* RFC 9068 asks for a distinct audience per resource, so that a token for one service does not work on another.
* A compromised API must not reach every VM of every tenant.
* The rule must also fit services added later, such as an object store.

## Considered options

* An exchange of tokens (RFC 8693) at Authentik: the API trades the token of the user for one of the Incus application.
* One OIDC application for the console, the API and Incus.
* The console signs in through the Incus application and the API accepts two issuers.
* A certificate held by the API.

## Decision outcome

Chosen option: "an exchange of tokens", because it keeps one application per service, keeps the Incus client private to Incus, and was measured to work on the platform (see [the audit](../explanation/rights-management-audit.md)).

* The provider `Phorge OAuth` gets the grant `urn:ietf:params:oauth:grant-type:token-exchange`, and the provider `Incus OAuth` lists `Phorge OAuth` as a federated provider, both in the blueprints.
* The API sends the access token of the user as `subject_token` with `audience` set to the Incus client ID, and `scope=openid email`. It holds the new token in memory for the session only.
* The group `iaas-users` still has to contain the person, as the policy of the Incus application applies to them. How self-service users enter it is decided with the build.
* A service that later needs a relayed identity gets its own application and lists the exchanging provider; one audience per exchange.
* Incus does not end a running session when `can_exec` is removed (measured, 92 seconds and still open). The relay of the API rechecks the right of the person in its own store at a fixed interval and closes the session itself, and enforces a maximum duration and an idle timeout.

### Consequences

* Good, because the console token is not valid on Incus and the Incus client is not shared.
* Good, because the API holds no Incus credential and Incus decides, through its own store.
* Good, because the same rule serves the next service.
* Bad, because the terminal depends on Authentik at the moment it opens, and each opening costs one exchange.
* Bad, because the closing of a revoked session is the relay's job, not Incus's, and has to be built and tested there.
* Neutral: the exchange is impersonation, so the token has no `act` claim and Incus logs the person, not the API.

### Confirmation

The relay is tested with a fake Incus, and end to end on the platform: a person with the right opens a terminal, a person without it is refused, and a session ends within the recheck interval after the right is removed.

## Pros and cons of the options

### An exchange of tokens

* Good, because it follows RFC 8693 and the Incus rule on its client ID.
* Bad, because of the dependency on Authentik at opening.

### One application for all services

* Bad, because it breaks the Incus rule on its client ID and the audience separation.

### The console through the Incus application, two issuers

* Bad, because it shares the Incus client ID too.

### A certificate held by the API

* Bad, because a compromised API reaches every VM of every tenant.

## More information

* [Audit of the management of rights](../explanation/rights-management-audit.md), [phorge-fr/phorge-api#31](https://github.com/phorge-fr/phorge-api/issues/31), [phorge-fr/Ansible#70](https://github.com/phorge-fr/Ansible/issues/70).
