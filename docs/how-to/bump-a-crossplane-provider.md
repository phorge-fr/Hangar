---
type: how-to
audience: maintainer releasing a Crossplane provider
verified: 2026-10-28
---

# Bump a Crossplane provider

After `provider-incus`, `provider-openfga` or `provider-authentik` publishes a release, open the Hangar pull request yourself right away; do not wait for Renovate. A fixed provider that is published but not deployed leaves the cluster on the old version.

1. Release pull request (release-please) merged, tag, publish workflow green.
2. Check that the package exists in both registries (`docker manifest inspect` against `ghcr.io` and `xpkg.upbound.io`).
3. Branch from `origin/main` (a `git worktree` if the main checkout holds someone's branch) and bump `overlays/control/controllers/crossplane/provider-<name>.yml`. Pull request in English, `Closes #N`.
4. After the merge, force Flux (`reconcile.fluxcd.io/requestedAt` on the GitRepository and on `overlay-controllers`) and check on `control`: both Providers `HEALTHY` on the new revision (the pull on the ARM nodes takes one to two minutes; `HEALTHY=False` meanwhile is normal), managed resources still `READY`, no errors in the provider logs.

`provider-openfga` carries a patched `terraform-provider-openfga` so that `AuthorizationModel` can reconcile (`openfga-phorge-model.yml` needs version 0.1.1 or later).
