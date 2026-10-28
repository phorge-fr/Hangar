# 0001: Cilium default-deny on every cluster

Status: accepted, live on `control`, `core` and `svc` since the policy rollout (pull request #223).

## Context

Pods could talk to everything. Every cluster should be covered without breaking running flows.

## Decision

- A `CiliumClusterwideNetworkPolicy` `default-deny` (DNS egress only) plus `allow-cilium-health`, and one `CiliumNetworkPolicy` per workload, shipped **in the same pull request as the workload**. A workload merged without one is born enforced and unreachable.
- Policies live in `base/apps/network-policies/`, `base/controllers/*/networkpolicy.yml` and per app in `overlays/<cluster>/...`.
- **No Cilium host firewall.** HostNetwork pods (Alloy, the NFS CSI driver, the node-local load balancer, Cilium) stay without policies: the Ansible `firewall` role (nftables, `enforce` on the clusters and the storage node) already default-denies their inbound traffic. The gain (egress and pod granularity) is not worth the agent restarts and the risk of cutting SSH, etcd or the API server. Do not propose it again.

## Consequences and pitfalls

- Capture real flows first (`cilium-dbg monitor -t trace -t drop -t policy-verdict` on every agent for about ten minutes, plus `cilium-dbg bpf ct list global` for long-lived connections), set `PolicyAuditMode=Enabled` on the endpoints **before** applying, watch the `action audit` verdicts, fix, then disable audit. A pod restarted during audit is enforced immediately. Loops over many endpoints exceed typical tool timeouts: run them in the background.
- Flux reverts a live edit of any object that exists in Git. For a live test add a new object instead of editing a Git-owned one; if you must patch one, use `kubectl replace` and check the BPF policy (`cilium-dbg bpf policy get <id>` must show no `Allow Egress ANY ANY`), because `kubectl apply` does not remove a field absent from the manifest when the live object has no last-applied annotation.
- Alloy is hostNetwork: its scrapes and probes arrive from the `host` and `remote-node` entities, so every scraped pod needs `fromEntities: host, remote-node`. In-cluster Prometheus (on `core`) scrapes directly and needs the Prometheus pods allowed too.
- `toFQDNs` is unusable (the L7 proxy is disabled): egress to the Internet is `world` on 443 or 53. Services that reach the public sign-in hostname go through the public address, so they are `world` too.
- A policy selecting a pod enables default-deny for that direction, but a Helm chart's own allow-all `NetworkPolicy` still wins by union: disable it in the chart values.
- Hubble was left out for now (cost question open).
