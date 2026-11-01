---
status: accepted
date: 2026-10-26
decision-makers: l-nmch
---

# Authentik is configured only through blueprints

## Context and problem statement

Authentik objects (flows, applications, service accounts, tokens) can be created by hand, by API, or declared in blueprints. How do we keep the repository the source of truth?

## Decision drivers

* A reset plus a Flux resync must rebuild the platform without manual steps.
* No unused or hand-copied secret.

## Considered options

* Blueprints in the repository only.
* Imperative steps with `ak shell` or the API, documented.

## Decision outcome

Chosen option: "blueprints only", because an unused or hand-copied secret is drift. A SOPS secret is acceptable only if something in the cluster consumes it.

### Consequences

* Good, because the platform rebuilds from Git.
* Bad, because some Authentik behavior needs workarounds in blueprints (below).

## Pros and cons of the options

### Blueprints only

* Good, because reviewable and repeatable.
* Bad, because a blueprint creates objects of its own list only: what Crossplane creates later (the service accounts and tokens of the API keys, created through `provider-http`) is not in a blueprint. Its service account and its role are, so the permissions it holds stay in Git.

### Imperative steps

* Good, because quick.
* Bad, because untracked state; a rebuild loses it.

## More information

* A credential shared between Authentik and a workload is generated once and stored in two SOPS secrets that are both consumed: Authentik reads it with `!Env` in the blueprint, the workload with `secretKeyRef`.
* Authentik 2026.8: an `authentik_core.token` entry accepts `key`; a blueprint grants object-level permissions on an entry (`permissions:`), and global permissions on a role (`permissions:` on an `authentik_rbac.role` entry, checked on 2026.8.5 by a dry run), so scope a service account to the objects it needs; `Importer.validate()` is a dry run and safe against production.
* The default sign-in flow cannot be renamed because default blueprints are re-applied; Phorge has its own ([hardening](../explanation/authentik-sign-in-hardening.md)).
* Applying a blueprint ConfigMap and the HelmRelease environment it reads in the same change leaves the instance in `error` until the hourly re-apply.
