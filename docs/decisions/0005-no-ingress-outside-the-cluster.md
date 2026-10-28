---
status: accepted
date: 2026-10-26
decision-makers: l-nmch
---

# A cluster's ingress never routes outside the cluster

## Context and problem statement

Tenant instances of the Incus platform need HTTP and TCP exposure. A first idea was to use the Kubernetes ingress as the dynamic layer. Should a cluster's ingress route to targets outside the cluster?

## Decision drivers

* The IaaS plane and the Kubernetes planes must stay independent.
* `control` runs on small ARM boards; tenant traffic would load it.

## Considered options

* Route tenant traffic through Traefik (`IngressRoute`, `IngressRouteTCP`, `ExternalName` or `Endpoints` to outside addresses).
* A platform-owned proxy on the Incus side, reached through a static address.

## Decision outcome

Chosen option: "a proxy on the Incus side", because it keeps the data path of the IaaS out of the control-plane cluster. The router only gets static pipes from `phorge-fr/Network`, and `control` gets no router access.

### Consequences

* Good, because the planes stay independent.
* Bad, because the `Expose` kind is deferred until a safe mechanism is found; a restricted-rights router token does not work since RouterOS cannot scope write rights per path.

## Pros and cons of the options

### Traefik for tenant traffic

* Good, because the machinery exists.
* Bad, because it couples the IaaS to the clusters. Banned; do not propose it again.

### Proxy on the Incus side

* Good, because it matches the boundary.
* Bad, because it is new work.
