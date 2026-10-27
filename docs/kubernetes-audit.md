# Kubernetes audit log

The API server of each cluster (`control`, `core`, `svc`) writes an audit record for every request that matters: who (user, groups, address, tool), did what (verb, resource, namespace, name), when, and with which result. Alloy ships the records to the Loki of core and the dashboard "Kubernetes audit" (folder Core, uid `k8s-audit`) reads them.

## How it works

1. **The API server** (`kube-apiserver` of k0s, run by `k0scontroller` as the user `kube-apiserver`) writes a JSON file, `/var/lib/k0s-audit/audit.log`, on every control plane node. The flags are in `spec.api.extraArgs` of `clusters/<cluster>/setup/k0s-cluster.yml`. The file is only a buffer: 3 files of 100 MiB at most, 3 days (`audit-log-maxsize`, `audit-log-maxbackup`, `audit-log-maxage`). Loki is the record.
2. **The policy** is `clusters/audit-policy.yaml`, shared by the three clusters and uploaded by k0sctl to `/etc/k0s/audit-policy.yaml`. The first rule that matches a request decides its level:
   - left out: health, metrics and discovery URLs; the kubelets and the control plane talking to itself; events, leases, endpoints and status updates; token and permission reviews; the **reads** of the service accounts of the applications (Flux, Crossplane, Cilium, cert-manager).
   - `Metadata` (who, what, when, from where, result, never the content): every access to a secret, a configmap or a service account token, by anybody; and everything else not listed, reads by people included.
   - `RequestResponse`: every change of a role or a binding (RBAC).
   - `Request`: `exec`, `attach`, `port-forward` (the command is in the URI).
   The policy was loaded with the validator of Kubernetes itself (`k8s.io/apiserver` v0.36.4, the version of k0s 1.36) and sixteen sample requests were checked against the level they must get (a kubelet reading a secret: none; Flux reading a secret: metadata; an administrator creating a role binding: request and response; and so on). The API server does not start with an invalid policy, so do this again after any change: a small Go program that calls `policy.LoadPolicyFromFile` and `NewPolicyRuleEvaluator(...).EvaluatePolicyRule(...)` is enough.
3. **The directory** `/var/lib/k0s-audit` has to belong to `kube-apiserver` (it cannot create it under `/var/lib`). A systemd drop-in (`clusters/k0scontroller-audit-dir.conf`, uploaded to `/etc/systemd/system/k0scontroller.service.d/audit-dir.conf`) creates it at each start of `k0scontroller`; the `-` in front of the command keeps a new node from failing to start before k0s has created the user. `/var/log` is not used: on `svc` it is a 47 MiB volume in memory.
4. **Alloy** (`base/controllers/alloy` for `control` and `svc`, `overlays/core/controllers/alloy` for `core`) tails `/host/root/var/lib/k0s-audit/audit.log` with the labels `job="k8s-audit"` and `node`; the writer adds `cluster`. The lines are sent untouched. The read position is kept in `/var/lib/alloy-data` on the node, so a restart of Alloy neither loses nor repeats lines.
5. **The dashboard** reads `{job="k8s-audit"} | json`. The fields are `user_username`, `sourceIPs_0`, `userAgent`, `verb`, `objectRef_resource`, `objectRef_namespace`, `objectRef_name`, `objectRef_subresource`, `objectRef_apiGroup`, `responseStatus_code`, `requestURI`.

```
{job="k8s-audit", cluster="core"} | json | verb=~"create|update|patch|delete" | user_username !~ "system:serviceaccount:.*"
{job="k8s-audit"} | json | responseStatus_code=~"401|403"
{job="k8s-audit"} | json | objectRef_resource="secrets" | user_username !~ "system:serviceaccount:flux-system:.*"
```

## Turning it on, cluster by cluster

Everything that Flux manages (Alloy, the dashboard) is deployed by the merge and does nothing until the file exists. The API server changes only when k0sctl is applied, which restarts the controllers one after the other; the cluster has three, so it stays up, but do **one cluster at a time**, least critical first (`svc`, then `core`, then `control`), and check each before the next. Do not do it while the end-to-end tests of the API run on `control`.

For each cluster, from `clusters/<cluster>/setup`:

1. Create the directory on the three nodes (the drop-in does it at each start, but k0sctl may restart before systemd has read the new drop-in):
   ```
   for ip in <the three node addresses>; do ssh root@$ip 'install -d -o kube-apiserver -g kube-apiserver -m 0750 /var/lib/k0s-audit'; done
   ```
2. Apply, as in the README of the cluster (the VRRP password is SOPS-encrypted and k0sctl does not read SOPS):
   ```
   sops -d --in-place k0s-cluster.yml
   ../../../k0sctl/k0sctl apply -c k0s-cluster.yml
   sops -e --in-place k0s-cluster.yml
   ```
   Before the first apply, `/etc/k0s/k0s.yaml` of every cluster was compared with the config in Git: they are identical apart from the node addresses that k0sctl adds to `api.sans` and the encrypted password, so the apply changes nothing but the audit.
3. Check: `kubectl get nodes` (all Ready), `ssh root@<node> 'ls -l /var/lib/k0s-audit; tail -n1 /var/lib/k0s-audit/audit.log'` (the file grows), and in Grafana `{job="k8s-audit", cluster="<cluster>"}` has lines from the three nodes.

If a node does not come back (the API server refuses an option), the other two keep the cluster up: on that node remove the `audit-*` lines from `/etc/k0s/k0s.yaml` and run `systemctl restart k0scontroller`, then fix the config in Git.

## What it does not cover

- Access to a node (SSH, `kubectl debug node`), to etcd or to the kubelet API directly: the audit log is the one of the API server. SSH logins are in the journal of each node, not collected here.
- The `comp` cluster (Incus) has its own audit: Incus lifecycle events are not collected yet (only its logs are: see `incus-logs-dashboard` and `logging` in `group_vars/compute.yml` of the Ansible repo).
- The content of a secret or a configmap is never in the log, but a command line given to `exec`, and the query string of any request, are in the URI: do not type a secret in a command.
- Reads by service accounts are not recorded (volume): a stolen service account token that only reads (apart from secrets, which are recorded) leaves no trace.

## Personal data and retention

The records hold the user name (a person's certificate, or a service account), the address and the tool of the client. That is administrators' data: see [gdpr.md](gdpr.md). On the node the file lives 3 days; in Loki the lines follow the retention of Loki (30 days). Whether the audit of the administrators' actions should be kept longer than the other logs is a decision for the report (one year is common for this kind of record); a retention per stream (`retention_stream` for `{job="k8s-audit"}`) can give it its own period once the volume is known.
