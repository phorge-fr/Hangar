# Runbooks

How to operate, test and debug the parts that the manifests do not explain. Decisions (why) are in [../decisions/](../decisions/README.md).

| Runbook | When to read it |
| --- | --- |
| [flux-live-testing.md](flux-live-testing.md) | You want to test a change to a Flux-managed resource on a live cluster before the pull request |
| [monitoring-scrape-gotchas.md](monitoring-scrape-gotchas.md) | Adding a scrape (Flux, Longhorn, cert-manager) or a dashboard on Flux objects, or a series is missing |
| [grafana-dashboard-check.md](grafana-dashboard-check.md) | You must prove that a dashboard renders, not only that its queries return data |
| [authentik-oidc-gotchas.md](authentik-oidc-gotchas.md) | Working on the OIDC application of the Phorge API or its device flow |
| [router-monitoring.md](router-monitoring.md) | The Network dashboard went empty |
| [provider-bump.md](provider-bump.md) | A Crossplane provider release was published |

Existing reference pages: [k0sctl apply](../k0sctl-apply.md), [Authentik hardening](../authentik-hardening.md), [HTTP audit](../http-audit.md), [Kubernetes audit](../kubernetes-audit.md), [GDPR notes](../gdpr.md).
