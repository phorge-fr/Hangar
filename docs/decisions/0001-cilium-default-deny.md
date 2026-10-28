---
status: accepted
date: 2026-10-27
decision-makers: l-nmch
---

# Cilium default-deny on every cluster, no host firewall in Cilium

## Context and problem statement

Pods could talk to everything on the three clusters. Every cluster should be covered without breaking running flows (Hangar pull request #223).

## Decision drivers

* Cover all three clusters, not only the ones that hold sensitive services.
* No outage during the rollout.
* Keep the node-level firewall (Ansible `firewall` role, nftables) as the layer for hostNetwork pods.

## Considered options

* A cluster-wide default-deny plus one `CiliumNetworkPolicy` per workload.
* The same, plus the Cilium host firewall for hostNetwork pods.
* Only the namespaces that hold secrets.

## Decision outcome

Chosen option: "default-deny plus one policy per workload", because it covers every cluster with a model that is easy to review, and the node firewall already default-denies the inbound traffic of hostNetwork pods.

The deny is a `CiliumClusterwideNetworkPolicy` `default-deny` (DNS egress only) plus `allow-cilium-health`. A workload ships its policy **in the same pull request**: a workload merged without one is born enforced and unreachable. Policies live in `base/apps/network-policies/`, `base/controllers/*/networkpolicy.yml` and per app in `overlays/<cluster>/...`.

### Consequences

* Good, because every flow is explicit and reviewable.
* Bad, because every new workload needs a captured set of flows (see [the live test how-to](../how-to/test-a-flux-change-live.md)).
* Bad, because hostNetwork pods (Alloy, the NFS CSI driver, the node-local load balancer, Cilium) have no policy.

### Confirmation

`cilium-dbg bpf policy get <id>` of an endpoint shows no `Allow Egress ANY ANY`; Hubble is not used.

## Pros and cons of the options

### Default-deny plus one policy per workload

* Good, because uniform on all clusters.
* Bad, because a mistake costs a workload its connectivity until the policy is fixed.

### Plus the Cilium host firewall

* Good, because it would add egress control and pod granularity for hostNetwork pods.
* Bad, because it requires agent restarts and risks cutting SSH, etcd or the API server, for little gain over nftables. Dropped by the maintainer on 2026-10-27; do not propose it again.

### Only the sensitive namespaces

* Good, because it is less work.
* Bad, because it leaves gaps and a second rule to remember.

## More information

* Method that worked: capture real flows with `cilium-dbg monitor -t trace -t drop -t policy-verdict` on every agent for about ten minutes plus `cilium-dbg bpf ct list global`; set `PolicyAuditMode=Enabled` on endpoints **before** applying; watch the `action audit` verdicts; then disable audit. A pod restarted during audit is enforced at once.
* Flux reverts a live edit of an object that exists in Git. For a live test add a new object. If you must patch one, use `kubectl replace`, because `kubectl apply` leaves a field absent from the manifest when the live object has no last-applied annotation.
* Alloy is hostNetwork: its scrapes arrive from the `host` and `remote-node` entities, so every scraped pod needs `fromEntities: host, remote-node`.
* `toFQDNs` is unusable (the L7 proxy is disabled): Internet egress is `world` on 443 or 53.
* A Helm chart's own allow-all `NetworkPolicy` still wins by union: disable it in the chart values.
