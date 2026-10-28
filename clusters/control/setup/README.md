# Control Cluster

The **Control** cluster is the main entry point of the infrastructure. It acts as the control plane, allowing users to provision resources and access them through multiple APIs

## Prerequisites

- [`k0sctl`](https://github.com/k0sproject/k0sctl)
- [`cilium`](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)
- [`flux`](https://fluxcd.io/flux/installation/)
- [`age`](https://github.com/FiloSottile/age)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)

## Deployment

### 1. Deploy the cluster, or apply a change to it

`k0s-cluster.yml` has its `authPass` (VRRP/Keepalived) field SOPS-encrypted and k0sctl does not understand SOPS, so it is applied from a decrypted copy: the tracked file is never touched (decrypting and encrypting it `--in-place` rewrites the whole file and leaves a diff). What `k0sctl apply` does with this config, and why the steps below are in this order, is in [docs/explanation/k0sctl-apply-behavior.md](../../../docs/explanation/k0sctl-apply-behavior.md): read it before the first apply. In short, **`k0sctl apply` stops, reinstalls and starts the k0s service of every host that has an uploaded file whose date differs from the remote one**, so the API server of each node is down for 30 to 90 seconds.

Every command below uses absolute paths built from `$REPO`: it works from any directory inside the repository, and nothing depends on where the terminal is. The values of this cluster are set once, here, so a block cannot be run with the values of another cluster:

```bash
C=control
IPS="10.1.0.1 10.1.0.2 10.1.0.3"
PUB=api.phorge.fr
REPO=$(git rev-parse --show-toplevel)
SETUP=$REPO/clusters/$C/setup
echo "cluster $C, config $SETUP/k0s-cluster.yml"; kubectl --context $C get nodes
```

One cluster at a time, on the merged `main` with nothing modified (`git -C "$REPO" pull --ff-only; git -C "$REPO" status --short`):

1. Set the date of the files that `k0s-cluster.yml` uploads to the date of their last commit. The date of a file in a Git checkout is the date of the checkout, so without this every fresh checkout or branch change looks like a change and restarts every controller at the next apply:

   ```bash
   for f in clusters/audit-policy.yaml clusters/k0scontroller-audit-dir.conf clusters/$C/setup/k0scontroller-gomemlimit.conf; do
       touch -d "$(git -C "$REPO" log -1 --format=%cI -- "$f")" "$REPO/$f"
   done
   ```

2. Create the directory of the API server audit log on the nodes (the drop-in that creates it at each start is read by systemd at the restart; whether that is soon enough for the very first start has not been verified):

   ```bash
   for ip in $IPS; do ssh root@$ip 'install -d -o kube-apiserver -g kube-apiserver -m 0750 /var/lib/k0s-audit'; done
   ```

3. Decrypt a copy (ignored by Git) and read the plan. `--concurrency 1` configures one host at a time (the default is 30 at once). `k0s will be upgraded` on a host means that its service will be stopped, reinstalled and started. The addresses of the hosts in the plan must be the ones of `$IPS`:

   ```bash
   export SOPS_AGE_KEY_FILE="$REPO/age.agekey"     # the key, by its absolute path ($REPO/.env holds it as a relative one)
   sops -d "$SETUP/k0s-cluster.yml" > "$SETUP/.k0s-cluster.apply.yml"
   "$REPO/k0sctl" apply --dry-run --concurrency 1 -c "$SETUP/.k0s-cluster.apply.yml"
   ```

4. In another terminal, probe the API and the public address while it runs, and keep the output (the values are written in, this terminal has no variables):

   ```bash
   while sleep 1; do printf '%s ' "$(date +%T)"; kubectl --context control get --raw /readyz --request-timeout=2s >/dev/null 2>&1 && printf 'api-ok ' || printf 'API-FAIL '; curl -s -m3 -o /dev/null -w '%{http_code}\n' https://api.phorge.fr/; done
   ```

5. Apply, then remove the copy, whatever the result (it holds the VRRP password in clear):

   ```bash
   "$REPO/k0sctl" apply --concurrency 1 -c "$SETUP/.k0s-cluster.apply.yml"; rm -f "$SETUP/.k0s-cluster.apply.yml"
   ```

6. Check that every node is Ready and runs a new API server with the memory limit and the audit flags:

   ```bash
   kubectl --context $C get nodes
   for ip in $IPS; do ssh root@$ip 'p=$(pgrep -f "^/var/lib/k0s/bin/kube-apiserver" | head -1); echo "$(hostname): api-server $p, $(tr "\0" "\n" </proc/$p/environ | grep ^GOMEMLIMIT=), $(tr "\0" " " </proc/$p/cmdline | grep -o "audit-log-path=[^ ]*"), $(ls -l /var/lib/k0s-audit/audit.log | cut -d" " -f5) bytes"'; done
   kubectl --context $C get pods -A | grep -v -E "Running|Completed"
   ```

If it fails, `/etc/k0s/k0s.yaml` is the config that k0sctl wrote: keep a copy of it from every node (`scp`) before the first apply of a change, and the other two controllers keep the cluster up while one is down. For a cluster that does not exist yet, the same command installs it (without the dry run and the probes).

### kube-apiserver memory limit

`k0s-cluster.yml` uploads `k0scontroller-gomemlimit.conf` to `/etc/systemd/system/k0scontroller.service.d/gomemlimit.conf` on every node, which sets `GOMEMLIMIT=1100MiB` for `k0scontroller` and so for everything k0s spawns (kube-apiserver, etcd, kubelet). Without it the Go garbage collector lets the apiserver heap reach about twice the live heap (`GOGC=100`), and the apiserver is the largest process on every node.

The value is about 1.4 to 1.9 times the estimated peak live heap of this cluster's apiserver (~770 MiB): a limit closer to the live heap makes the GC run continuously (an A/B on `svc` with 700 MiB against a ~460 MiB peak showed GC CPU spikes four times higher than without the limit). Check `go_cpu_classes_gc_total_cpu_seconds_total` for the apiserver job before lowering it.

`k0sctl apply` uploads the file and restarts the controllers when its date differs from the remote one (the first time it did, on 2026-10-28, because the file had been put on the nodes by hand; the value in the API server process environment was then checked on every node). Nothing has to be restarted by hand: a change of the value is an apply of this cluster, as in step 1 above. Check `go_cpu_classes_gc_total_cpu_seconds_total` of the apiserver job after a change.

### Kubernetes audit log

The API server writes an audit log (`audit-*` flags of `k0s-cluster.yml`, policy `../../audit-policy.yaml`, buffer `/var/lib/k0s-audit/audit.log` on every node), which Alloy ships to Loki. See [docs/explanation/kubernetes-audit-log.md](../../../docs/explanation/kubernetes-audit-log.md). A change of the policy needs the API server to restart, so it is an apply of this cluster as in step 1.

### 2. Retrieve the kubeconfig

```bash
k0sctl kubeconfig -c k0s-cluster.yml > kubeconfig
export KUBECONFIG=$PWD/kubeconfig
```

### 3. Install Cilium

```bash
cilium install --version 1.19.2 \
  --helm-set ipam.operator.clusterPoolIPv4PodCIDRList="10.244.0.0/16" \
  --helm-set envoy.enabled=false \
  --helm-set l7Proxy=false \
  --helm-set l2announcements.enabled=true \
  --helm-set bpf.masquerade=true \
  --helm-set hubble.enabled=false \
  --helm-set bpf.mapDynamicSizeRatio=0.001 \
  --helm-set bpf.distributedLRU.enabled=false \
  --helm-set bpf.ctTcpMax=131072 \
  --helm-set bpf.ctAnyMax=65536 \
  --helm-set bpf.natMax=131072
```

```bash
kubectl apply -f l2announcementpolicy.yml
kubectl apply -f ip-pools.yml
```

### 4. Create the SOPS age secret

This key is used by Flux to decrypt secrets managed with SOPS.

```bash
age-keygen -o age.agekey
kubectl create namespace flux-system
cat age.agekey | kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
rm age.agekey
```

### 5. Bootstrap Flux

```bash
flux bootstrap github \
  --owner=phorge-fr \
  --repository=Hangar \
  --branch=main \
  --path=clusters/control \
  --token-auth=true
```