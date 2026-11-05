---
type: reference
audience: maintainers who add, rotate or review a credential on the control cluster
verified: 2026-11-05
---

# Credentials held on the control cluster

Every credential that opens another system, and the rights it carries, as of the date above. The rule is in [the decision record](../decisions/0011-control-carries-no-full-admin-secret.md): no credential on `control` gives full access to the system it opens.

Not listed: the TLS pairs that Crossplane and its providers generate to talk to each other (`crossplane-tls-*`, `provider-*-tls-*`, `function-*-tls-*`), the certificates cert-manager issues for ingress, and the service account tokens of Kubernetes. They open nothing outside the cluster.

## Credentials

| Secret | Opens | What it permits | Status |
| --- | --- | --- | --- |
| `provider-incus-creds` (`crossplane-system`) | Incus | Create projects and use the objects of the projects named `t-*`, through a restricted client certificate limited by an Incus scriptlet. It cannot administer the server. | In line |
| `provider-http-authentik` (`crossplane-system`) | Authentik | The service account `crossplane-provider`, not a superuser: add a user, add and view tokens, and delete or view only the accounts it created. | In line |
| `provider-openfga-creds` (`crossplane-system`) | OpenFGA | An OpenFGA preshared key: read and write every store (`iaas` and `phorge-api`). | Open: [Hangar#300](https://github.com/phorge-fr/Hangar/issues/300), waiting for an OpenFGA release |
| `phorge-api-openfga` (`phorge-api`) | OpenFGA | Another preshared key of the same kind: read and write every store. It is separate so that it can be rotated alone. | Open: [Hangar#300](https://github.com/phorge-fr/Hangar/issues/300) |
| `sops-age` (`flux-system`) | The SOPS files of this repository | The age key that decrypts them. One key is shared today, so it decrypts the Secrets of every cluster. | Open: [Hangar#267](https://github.com/phorge-fr/Hangar/issues/267) |
| `cloudflare-api-token-secret` (`cert-manager`) | Cloudflare | The DNS-01 challenge of cert-manager. Its exact scope is not recorded in the repository. | Open: [Hangar#338](https://github.com/phorge-fr/Hangar/issues/338) |
| `alloy-secrets` (`alloy`) | The ingress of `core` | Basic authentication of Alloy, to send the logs and metrics of `control` to `core`. | In line |

## Rights that are not a Secret

| Holder | What it permits | Status |
| --- | --- | --- |
| Service account of Crossview | Read every resource of every API group of `control`, Secrets included. Sign-in is limited to the authentik group `crossview-users`. | Open: [Hangar#339](https://github.com/phorge-fr/Hangar/issues/339) |
| Service account of provider-kubernetes | Create and own the `t-<name>` namespaces of the Tenant composition, nothing else. `control` holds no credential towards `core`. | In line |
| Service account of the Phorge API | Manage the `phorge.fr` kinds, and read once, then delete, the key of an API key. | In line |

## Keep it current

A pull request that adds, replaces or widens a credential on `control` changes this page in the same pull request. A credential that is not in line gets an issue before it gets a row.
