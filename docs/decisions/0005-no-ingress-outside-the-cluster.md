# 0005: A cluster's ingress never routes outside the cluster

Status: accepted.

## Decision

An ingress controller (Traefik `IngressRoute`, `IngressRouteTCP`, `ExternalName` or `Endpoints` pointing at outside addresses) serves that cluster's workloads only. It must not route to targets outside the cluster, in particular tenant instances of the Incus platform.

## Why

Putting tenant traffic through a cluster ingress couples the data path of the IaaS to the control-plane cluster (which runs on small ARM single-board computers) and blurs the boundary between the clusters and the Incus platform. The IaaS and Kubernetes planes stay independent.

## Consequences

Exposure of tenant HTTP or TCP services keeps its dynamic routing layer on the Incus side (a platform-owned proxy in an Incus project, reached through a static address). The router only gets static pipes from `phorge-fr/Network`, and `control` gets no router access. The `Expose` kind is deferred until a safe mechanism is found. Do not propose the Traefik route again.
