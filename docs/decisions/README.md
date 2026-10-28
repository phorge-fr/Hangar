# Decision records

Short records of choices that shaped the platform, with the reason and what was ruled out, so they are not re-litigated by accident. A new record gets the next number and is added to this list in the same pull request.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-cilium-default-deny.md) | Cilium default-deny on every cluster, no host firewall in Cilium | Accepted |
| [0002](0002-apiserver-memory.md) | Bound the kube-apiserver memory with `GOMEMLIMIT` | Accepted |
| [0003](0003-godebug-madvdontneed-rejected.md) | `GODEBUG=madvdontneed=1` on Grafana | Rejected |
| [0004](0004-alerts-as-a-dashboard.md) | Show alerts in a dashboard, keep Prometheus rules as they are | Accepted |
| [0005](0005-no-ingress-outside-the-cluster.md) | A cluster's ingress never routes to targets outside the cluster | Accepted |
| [0006](0006-authentik-as-code.md) | Authentik is configured only through blueprints | Accepted |
| [0007](0007-tenant-policy.md) | Deny-all-by-default policy for tenant Incus projects | Accepted |
