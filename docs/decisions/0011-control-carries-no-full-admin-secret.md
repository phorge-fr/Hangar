---
status: accepted
date: 2026-11-05
decision-makers: l-nmch
---

# The control cluster carries no full-admin secret

## Context and problem statement

`control` is the most exposed cluster: Crossplane, the Phorge API and the console run there, and the API takes requests from outside. Crossplane and the API hold credentials towards Incus, OpenFGA and Authentik. If one of them gives full access to its system, the compromise of one workload on `control` is the compromise of that system.

How much may a credential held on `control` do?

## Decision drivers

* The platform is public and meant to be a clean reference: least privilege, no superuser except `akadmin` in Authentik.
* A restriction that the holder can lift itself protects nothing.
* A credential that cannot be limited today must be visible and tracked, not forgotten.

## Considered options

* Full-admin credentials on `control`, protected by the network policies and RBAC of the cluster.
* No full-admin credential on `control`: each credential reaches only what its holder needs, and the limit lives outside anything the holder can write.

## Decision outcome

Chosen option: "no full-admin credential on `control`", because the network policies protect the path to a system, not what a stolen credential does once it arrives.

The rule has two parts:

* A credential held on `control` is limited by the system it opens, in a place the holder cannot change. A right that Crossplane can write for itself does not count: the restricted Incus certificate is limited by an Incus scriptlet set by Ansible, not by OpenFGA tuples that Crossplane could extend ([how-to](../how-to/create-a-restricted-incus-client-certificate.md)).
* A credential that cannot be limited yet is listed in [the inventory](../reference/control-credentials.md) with the issue that tracks it. Nothing is added to `control` that would widen the list without an entry.

### Consequences

* Good, because a compromised workload on `control` reaches only what its own credential allows.
* Good, because the inventory shows at one glance what is still open.
* Bad, because some systems cannot limit a credential today: OpenFGA preshared keys read and write every store ([Hangar#300](https://github.com/phorge-fr/Hangar/issues/300), waiting for an OpenFGA release).
* Bad, because the inventory must be kept in step with the Secrets of `control`.

## More information

* [Credentials held on the control cluster](../reference/control-credentials.md)
* Epic: [Hangar#297](https://github.com/phorge-fr/Hangar/issues/297)
