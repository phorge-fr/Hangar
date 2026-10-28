---
type: how-to
audience: maintainer testing a change on a live cluster
verified: 2026-10-28
---

# Test a Flux change live

Use this for a HelmRelease, a ConfigMap or any object Flux owns, before opening the pull request. It tests byte for byte what will run once merged.

## Procedure

1. **Suspend the owning Kustomizations, parent included.** On `core` the `apps` Kustomization is itself declared in Git, so its parent `flux-system` resets `spec.suspend` to false on its next reconcile and `apps` then reverts your test with no error. Patch both: `{"spec":{"suspend":true}}` on `flux-system` and on the child.
2. **Decrypt the real repository file** to a scratch location (absolute `SOPS_AGE_KEY_FILE`; never in place on a tracked file), edit that file. Do not use `kubectl patch` (it races with an in-flight reconcile and is silently reverted) and do not call `helm upgrade` (it bypasses the HelmRelease and tests something else).
3. **`kubectl apply -f` the file.** helm-controller (not suspended) performs the real upgrade.
4. **Verify the live object still holds the change** (`kubectl get ... | grep`) before trusting any result.
5. Validate or refute, then re-encrypt for the commit.

## Resuming

- Merge the pull request first. Check `gh pr view N --json state` says `MERGED`: resuming Flux with an unmerged change reverts the test and can break the service (a sign-in captcha was cut for minutes that way).
- Run `flux reconcile source git flux-system` **before** `flux resume`, and check the artifact revision is the merge commit: otherwise Flux reconciles the cached pre-merge artifact first and can re-apply an old Deployment for a moment (two ingress outages of about 12 seconds were measured).
- Resume both Kustomizations (`suspend:false`) and check `kubectl -n flux-system get kustomization`.

## Pitfalls

- A HelmRelease created by Flux's server-side apply keeps keys you delete from the file when you `kubectl apply` it (for example `deploymentStrategy.rollingUpdate` left next to `type: Recreate`, then Helm fails with "Forbidden"). Compare live and repository `spec.values` and remove leftovers with a JSON patch.
- Helm cannot patch a Deployment from RollingUpdate to Recreate: delete the Deployment and `flux reconcile hr ... --force`.
- Do not edit a Git-owned object for a network-policy test; add a new object ([decision 0001](../decisions/0001-cilium-default-deny.md)).
- `kubectl apply` of a ConfigMap read by a dashboard sidecar is reverted at the next reconcile (about ten minutes): suspend first, even for a dashboard.
- Long loops (many endpoints) exceed typical tool timeouts: run them in the background.
