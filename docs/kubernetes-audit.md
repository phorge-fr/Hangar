# Kubernetes audit log

The API server of each cluster (`control`, `core`, `svc`) writes an audit record for every request that matters: who (user, groups, address, tool), did what (verb, resource, namespace, name), when, and with which result. Alloy ships the records to the Loki of core and the dashboard "Kubernetes audit" (folder Core, uid `k8s-audit`) reads them.

## How it works

1. **The API server** (`kube-apiserver` of k0s, run by `k0scontroller` as the user `kube-apiserver`) writes a JSON file, `/var/lib/k0s-audit/audit.log`, on every control plane node. The flags are in `spec.api.extraArgs` of `clusters/<cluster>/setup/k0s-cluster.yml`. The file is only a buffer: 3 files of 100 MiB at most, 3 days (`audit-log-maxsize`, `audit-log-maxbackup`, `audit-log-maxage`). Loki is the record.
2. **The policy** is `clusters/audit-policy.yaml`, shared by the three clusters and uploaded by k0sctl to `/etc/k0s/audit-policy.yaml`. The first rule that matches a request decides its level. **Who is audited** is the point of it:
   - **People** (a token or a certificate used with `kubectl`): everything, reads included, **except the admin certificate** (`kubernetes-admin`): k0s itself uses it and polls the whole API every 40 seconds or so (the nodes, the etcd members, a list of every kind of object), which was 97% of the first log on `svc` (2 700 records in 12 minutes on one node). The reads of that identity are left out; its changes, its secret accesses and its shells are kept.
   - **Service accounts** (Flux, Crossplane, Cilium, Longhorn, cert-manager, the applications): what they **change** (spec, not status), every access to a **secret**, and nothing else. Their reads, their status updates and their configmap reads are routine and constant, and are left out.
   - **Left out for everybody**: the kubelets and the control plane talking to itself; health, metrics and discovery URLs; leases (leader election and node heartbeats are about 11 requests a second on each cluster, the largest item by far), events, endpoints; token and permission reviews.
   - **Levels**: `Metadata` (who, what, when, from where, result, never the content) for almost everything, always for secrets; `RequestResponse` for every change of a role or a binding (RBAC); `Request` for `exec`, `attach`, `port-forward` (the command is in the URI). One record per request, when it is answered (`RequestReceived` and `ResponseStarted` are omitted).
   The policy was loaded with the validator of Kubernetes itself (`k8s.io/apiserver` v0.36.4, the version of k0s 1.36) and 24 sample requests were checked against the level they must get (a kubelet reading a secret: none; Flux reading a secret: metadata; Flux patching a HelmRelease status: none, its spec: metadata; an administrator creating a role binding: request and response; and so on). The API server does not start with an invalid policy, so do this again after any change: a small Go program that calls `policy.LoadPolicyFromFile` and `NewPolicyRuleEvaluator(...).EvaluatePolicyRule(...)` is enough. The list of groups whose status is left out is the one seen on 2026-10-27: a new kind of object that is not in it shows up in the log, which is the cue to add its group.
3. **The directory** `/var/lib/k0s-audit` has to belong to `kube-apiserver` (it cannot create it under `/var/lib`). A systemd drop-in (`clusters/k0scontroller-audit-dir.conf`, uploaded to `/etc/systemd/system/k0scontroller.service.d/audit-dir.conf`) creates it at each start of `k0scontroller`; the `-` in front of the command keeps a new node from failing to start before k0s has created the user. `/var/log` is not used: on `svc` it is a 47 MiB volume in memory.
4. **Alloy** (`base/controllers/alloy` for `control` and `svc`, `overlays/core/controllers/alloy` for `core`) tails `/host/root/var/lib/k0s-audit/audit.log` with the labels `job="k8s-audit"` and `node`; the writer adds `cluster`. The lines are sent untouched. The read position is kept in `/var/lib/alloy-data` on the node, so a restart of Alloy neither loses nor repeats lines.
5. **The dashboard** reads `{job="k8s-audit"} | json`. The fields are `user_username`, `sourceIPs_0`, `userAgent`, `verb`, `objectRef_resource`, `objectRef_namespace`, `objectRef_name`, `objectRef_subresource`, `objectRef_apiGroup`, `responseStatus_code`, `requestURI`.

```
{job="k8s-audit", cluster="core"} | json | verb=~"create|update|patch|delete" | user_username !~ "system:serviceaccount:.*"
{job="k8s-audit"} | json | responseStatus_code=~"401|403"
{job="k8s-audit"} | json | objectRef_resource="secrets" | user_username !~ "system:serviceaccount:flux-system:.*"
```

## Volume

An audit log of everything is enormous: the API servers answer about 25 requests a second each, 2.2 million a day (Prometheus, `apiserver_request_total`, 24 hours on 2026-10-27), and most of it is leases, health checks and kubelets. What the policy keeps, estimated from the same metrics by resource, verb and subresource:

| Cluster | Changes kept | Secret accesses (upper bound) | Records a day | About, uncompressed |
|---|---|---|---|---|
| core | 0.2 per second | 0.25 | 20 000 to 40 000 | 20 to 35 MB |
| control | 0.7 per second | 0.17 | 60 000 to 75 000 | 50 to 60 MB |
| svc | 0.13 per second | 0.09 | 10 000 to 20 000 | 10 to 15 MB |

The upper bound for the secrets counts the reads of the kubelets too, which the policy leaves out, and a record is about 0.8 KB. Loki compresses JSON like this by about ten. **Measured on 2026-10-28, with the policy of this page, about ten hours after each apply** (Loki, `{job="k8s-audit"}`):

| Cluster | Records | Bytes (uncompressed) | Per day | What fills it |
|---|---|---|---|---|
| `svc` | 7 109 in 10.5 h | 10.8 MB | about 16 000 records, 25 MB | `helm-controller` and `kustomize-controller` patches, secret reads and watches |
| `core` | 19 947 in 10 h | 30.4 MB | about 48 000 records, 73 MB | the same, plus Grafana and Longhorn watching secrets |
| `control` | 1 077 in 7 min, just after the restarts | | to measure again after a day (Crossplane updates its CRDs and managed resource definitions, 337 `update` of `managedresourcedefinitions` in the first 7 minutes) | Crossplane |

A record is about 1.5 KB, twice the 0.8 KB assumed, and the records are 1.2 to 2.4 times the estimate. Most of it is **Flux**: its two controllers apply with server-side apply, which is a `patch` that is recorded at every reconciliation even when nothing changes (`configmaps`, `ciliumnetworkpolicies`, `helmcharts`, `namespaces`, `secrets`), and read secrets for the decryption (`get`, `list`). Loki compresses this JSON about ten times, so the three clusters are roughly 15 to 25 MB a day stored, which is nothing for the volume of Loki. If it has to go down, the lever is to leave out the `patch` and `update` of the two Flux service accounts (what Flux applies is in Git, and the log would then say who did something by hand but not what Flux applied): not done, it is a decision about what the audit is for.

These are estimates from metrics, not measures: check them after the first day, with `sum(count_over_time({job="k8s-audit"}[1d]))` and `sum(bytes_over_time({job="k8s-audit"}[1d]))` in Loki, and with `rate(apiserver_audit_event_total[1h])` in Prometheus (the API server exposes it once the audit is on). If a cluster is louder than this, look at the top `user_username` and `objectRef_resource` of the dashboard: it is almost always one controller that is worth adding to the policy.

## Turning it on

Everything that Flux manages (Alloy, the dashboard) is deployed by the merge and does nothing until the file exists. The API server changes with `k0sctl apply`, following the procedure in the README of the cluster (`clusters/<cluster>/setup/README.md`); [k0sctl-apply.md](k0sctl-apply.md) says what the tool does and what was measured. Short version: one cluster at a time, `svc`, then `core`, then `control`; it stops and starts the k0s service of every controller one after the other, and the API server of each node is down for 30 to 90 seconds. Do not do it on `control` while the end-to-end tests of the API run. A change of `clusters/audit-policy.yaml` needs the same (the API server reads it when it starts).

`svc` was first configured by hand on 2026-10-27, before the dry run showed what `k0sctl apply` does; the apply of 2026-10-28 brought it back to what Git says. To check the audit afterwards: `ssh root@<node> 'tail -n1 /var/lib/k0s-audit/audit.log'`, and in Grafana `{job="k8s-audit", cluster="<cluster>"}` has lines from the three nodes.

## What it does not cover

- Access to a node (SSH, `kubectl debug node`), to etcd or to the kubelet API directly: the audit log is the one of the API server. SSH logins are in the journal of each node, not collected here.
- The `comp` cluster (Incus) has its own audit: Incus lifecycle events are not collected yet (only its logs are: see `incus-logs-dashboard` and `logging` in `group_vars/compute.yml` of the Ansible repo).
- **A shared identity.** Today every administrator uses the same certificate, `kubernetes-admin` (group `system:masters`), so the log says that the admin did something, not which person. That is enough for one administrator; with several, give each one an identity of their own (OIDC through Authentik, which the API server supports) before the audit is relied on to tell them apart. On the path through the control plane address, the source address of that identity is a node (`10.3.0.2` was seen for a `k9s` run from a workstation), not the workstation.
- The content of a secret or a configmap is never in the log, but a command line given to `exec`, and the query string of any request, are in the URI: do not type a secret in a command.
- Reads by service accounts are not recorded (volume): a stolen service account token that only reads (apart from secrets, which are recorded) leaves no trace.

## Personal data and retention

The records hold the user name (a person's certificate, or a service account), the address and the tool of the client. That is administrators' data: see [gdpr.md](gdpr.md). On the node the file lives 3 days; in Loki the lines follow the retention of Loki (30 days). Whether the audit of the administrators' actions should be kept longer than the other logs is a decision for the report (one year is common for this kind of record); a retention per stream (`retention_stream` for `{job="k8s-audit"}`) can give it its own period once the volume is known.
