# Hangar documentation

Pages are grouped by what the reader wants, following [the organization's documentation standard](https://github.com/phorge-fr/.github/blob/main/docs/reference/documentation-standard.md).

## Tutorials

None yet.

## How-to guides

| Page | Task |
| --- | --- |
| [Test a Flux change live](how-to/test-a-flux-change-live.md) | Try a change to a Flux-managed resource on a cluster before the pull request |
| [Bump a Crossplane provider](how-to/bump-a-crossplane-provider.md) | Deploy a provider after its release |
| [Reseal a k0s cluster file](how-to/reseal-a-k0s-cluster-file.md) | Sign `k0s-cluster.yml` again after a hand edit |
| [Enable the Kubernetes audit](how-to/enable-the-kubernetes-audit.md) | Turn the audit on, or change its policy, on a cluster |
| [Test an Alloy pipeline](how-to/test-an-alloy-pipeline.md) | Change an Alloy `loki.process` stage safely |
| [Check a Grafana dashboard](how-to/check-a-grafana-dashboard.md) | Prove a dashboard renders |
| [Fix an empty router dashboard](how-to/fix-an-empty-router-dashboard.md) | Restore the router monitoring |
| [Enrol MFA for an account](how-to/enrol-mfa-for-an-account.md) | Add a second MFA device |
| [Recover access to Authentik](how-to/recover-access-to-authentik.md) | Get back in after a lockout |
| [Measure cookies and third parties](how-to/measure-cookies-and-third-parties.md) | Re-measure the sign-in page after a change |

## Reference

| Page | Content |
| --- | --- |
| [Phorge API kinds](reference/phorge-api-kinds.md) | `Tenant`, `Image`, `Instance`, `Membership`, `ApiKey` |
| [Authentik sign-in layers](reference/authentik-sign-in-layers.md) | What protects the sign-in, in order |
| [Authentik OIDC facts](reference/authentik-oidc-facts.md) | Behaviors of Authentik 2026.8 that matter to the API |
| [GDPR personal data inventory](reference/gdpr-personal-data.md) | Cookies, third parties, personal data per system |
| [HTTP audit log fields](reference/http-audit-fields.md) | Fields and queries of the Traefik audit log |
| [Kubernetes audit log fields](reference/kubernetes-audit-fields.md) | Fields and queries of the API server audit log |

## Explanation

| Page | Question it answers |
| --- | --- |
| [How the Phorge API is built](explanation/phorge-api-implementation-plan.md) | How the API, the platform and the authorization fit together |
| [How k0sctl apply behaves](explanation/k0sctl-apply-behavior.md) | What `k0sctl apply` really does, measured |
| [Authentik sign-in hardening](explanation/authentik-sign-in-hardening.md) | Why the sign-in is built this way |
| [The HTTP audit log](explanation/http-audit-log.md) | How requests are logged, enriched and read |
| [The Kubernetes audit log](explanation/kubernetes-audit-log.md) | What is audited, how much, and what is not |
| [Monitoring scrape pitfalls](explanation/monitoring-scrape-pitfalls.md) | Why a scrape or a series can be missing |
| [GDPR: decisions still to take](explanation/gdpr-open-decisions.md) | Open choices on retention and visitor information |

## Decisions

See [the decision records](decisions/README.md).
