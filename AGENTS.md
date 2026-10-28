# AGENTS.md: Hangar

Instructions for anyone working in this repository, human or AI assistant. The organization-wide rules (issues, pull requests, time tracking, security reporting) are in [phorge-fr/.github](https://github.com/phorge-fr/.github/blob/main/AGENTS.md) and [GOVERNANCE.md](https://github.com/phorge-fr/.github/blob/main/GOVERNANCE.md); this file only adds what is specific to Hangar.

## What this repository is

The GitOps source of truth of the three Kubernetes clusters (`control`, `core`, `svc`), reconciled by Flux. Whatever is on `main` is what the clusters run. Secrets are encrypted with SOPS and age.

```
base/        shared manifests (controllers, configs, apps)
overlays/    per-cluster Kustomize overlays: controllers/, configs/, apps/, resources/
clusters/    per-cluster Flux entrypoints and setup guides (k0sctl)
docs/        reference pages, decisions/ (why) and runbooks/ (how)
tests/       end-to-end tests of the phorge.fr API kinds
```

The Phorge API code is **not** here: it lives in `phorge-fr/phorge-api`. Hangar holds its deployment manifests, the XRDs, the OpenFGA model and the plan (`docs/phorge-api*.md`). A platform change needed by the API is a pull request here.

## Workflow

- One issue per change, a short branch cut from the current `origin/main` (`feat/`, `fix/`, `docs/`), one pull request, `Closes #N` in its description. Never commit to `main`.
- Titles read `<cluster>/<subject>: Description` (`core/grafana: ...`, `all/security: ...` when it spans clusters). Text is in English.
- `main` is protected: the checks below and `governance / pr-governance` must pass. A merge deploys through Flux, so merging is a deliberate act.
- Renovate maintains dependencies. After a provider release, open the bump pull request yourself instead of waiting for Renovate ([runbook](docs/runbooks/provider-bump.md)).

## Checks (the CI runs the same)

- `kubectl kustomize <dir>` must build for every directory that has a `kustomization.yml`.
- `kubeconform -strict` on the rendered output (documents carrying a `sops` key are filtered out first).
- `yamllint --strict .` with `.yamllint.yml` (4-space indentation, sequences indented).

## Secrets

- Encrypted with SOPS and age; the rules are in `.sops.yaml`. The age key file (`age.agekey`) is gitignored and stays on the maintainer's machine: never print, copy or commit key material, and never decrypt a tracked file in place. Decrypt to a scratch file, edit, re-encrypt with `sops -e --filename-override <path>`, and verify that `sops -d` of the result equals what you edited.
- SOPS signs the whole file: editing a plain line of an encrypted file by hand breaks its MAC. See [docs/k0sctl-apply.md](docs/k0sctl-apply.md).
- A secret is only acceptable if something in the cluster consumes it. Everything in this repository must create something in the cluster; an unused or hand-copied secret is drift.
- Never commit credentials, addresses of private systems or exploitable findings. Findings go to a private security advisory, see the organization `SECURITY.md`.

## Rules specific to this repository

- **Use the repository's tool, never a shortcut.** k0s clusters through `k0sctl` (dry run first, see [docs/k0sctl-apply.md](docs/k0sctl-apply.md)), workloads through Flux, the router through `tofu` (in `phorge-fr/Network`), hosts through Ansible. If the tool looks risky, say so, use its safety options and measure; do not substitute SSH or ad-hoc `kubectl` edits. A hand change to something a tool manages must be reconciled by the tool afterwards.
- **Every new workload ships its `CiliumNetworkPolicy` in the same pull request.** Default-deny is live on all three clusters ([decision](docs/decisions/0001-cilium-default-deny.md)); an app without a policy is unreachable.
- **Authentik is configured only through blueprints in the repository**, never by hand ([decision](docs/decisions/0006-authentik-as-code.md)).
- **A cluster's ingress never points at a target outside that cluster** ([decision](docs/decisions/0005-no-ingress-outside-the-cluster.md)). Exposure of tenant workloads stays on the Incus side.
- **Test a change to a Flux-managed resource on the live cluster before the pull request**, with the procedure of [the live-testing runbook](docs/runbooks/flux-live-testing.md): suspend the owning Kustomizations, apply the real file, and resume only after the pull request is merged.
- **Measure before tuning.** Memory and performance changes are decided from before/after measurements, not from theory ([records](docs/decisions/README.md)).
- Tenant resources: `forceDestroy` on an Incus `Project` is acceptable only on a throwaway development spike, never in compositions that ship; image pulls are a managed `Image` resource, never left to an `Instance`.
- Respect the GDPR notes in [docs/gdpr.md](docs/gdpr.md) for anything that touches cookies, third-party content or logs of personal data.

## Where to look

- [docs/decisions/](docs/decisions/README.md): why things are the way they are.
- [docs/runbooks/](docs/runbooks/README.md): how to operate and test them.
- Cluster setup and `k0sctl`: `clusters/<cluster>/setup/README.md`.
- API kinds and plan: [docs/phorge-api.md](docs/phorge-api.md), [docs/phorge-api-implementation.md](docs/phorge-api-implementation.md).
