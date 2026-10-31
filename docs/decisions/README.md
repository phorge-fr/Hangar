# Decision records

Records of choices that shaped the platform, in [MADR 4.0](https://adr.github.io/madr/) format. A new record gets the next number and is added here in the same pull request. A record is never rewritten: a new one supersedes it.

| Record | Status |
| --- | --- |
| [0001 Cilium default-deny on every cluster, no host firewall in Cilium](0001-cilium-default-deny.md) | accepted |
| [0002 Bound the kube-apiserver memory with GOMEMLIMIT](0002-apiserver-memory.md) | accepted |
| [0003 GODEBUG madvdontneed=1 on Grafana](0003-godebug-madvdontneed-rejected.md) | rejected |
| [0004 Show alerts in a dashboard and keep the Prometheus rules](0004-alerts-as-a-dashboard.md) | accepted |
| [0005 A cluster's ingress never routes outside the cluster](0005-no-ingress-outside-the-cluster.md) | accepted |
| [0006 Authentik is configured only through blueprints](0006-authentik-as-code.md) | accepted |
| [0007 Deny-all-by-default policy for tenant projects](0007-tenant-policy.md) | accepted |
| [0008 Keep the svc cluster and host the frontend on it](0008-keep-svc-and-host-the-frontend-on-it.md) | accepted |
| [0009 Build the frontend with SvelteKit, UnoCSS and pnpm](0009-build-the-frontend-with-sveltekit.md) | accepted |
