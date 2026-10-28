# 0006: Authentik is configured only through blueprints

Status: accepted.

## Decision

Anything created in Authentik comes from a blueprint in this repository, never from an imperative `ak shell` or API step. A SOPS secret is acceptable only if something in the cluster consumes it.

## Why

The repository must be the source of truth, so that a reset plus a Flux resync rebuilds the platform without manual steps. An unused or hand-copied secret is drift.

## How

- A credential shared between Authentik and a workload is generated once and stored in two SOPS secrets that are both consumed: Authentik reads it with `!Env` in the blueprint, the workload with `secretKeyRef`.
- Facts of Authentik 2026.8 that make this possible: an `authentik_core.token` entry accepts `key`; a blueprint can grant object-level permissions only (`permissions:` on an entry), not model-level ones, so scope a service account to a single object; `Importer.validate()` is a dry run (rolled back) and safe against production.
- The default sign-in flow cannot be renamed because default blueprints are re-applied; Phorge has its own flow (see [docs/authentik-hardening.md](../authentik-hardening.md)).
- Applying a blueprint ConfigMap and the HelmRelease environment it reads in the same change leaves the instance in `error` for a while; blueprints are re-applied hourly.
