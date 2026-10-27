# Control Cluster

The **Control** cluster is the main entry point of the infrastructure. It acts as the control plane, allowing users to provision resources and access them through multiple APIs

## Prerequisites

- [`k0sctl`](https://github.com/k0sproject/k0sctl)
- [`cilium`](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)
- [`flux`](https://fluxcd.io/flux/installation/)
- [`age`](https://github.com/FiloSottile/age)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)

## Deployment

### 1. Deploy the cluster

`k0s-cluster.yml` has its `authPass` (VRRP/Keepalived) field SOPS-encrypted -- decrypt it in place before running `k0sctl` (it doesn't understand SOPS syntax), then re-encrypt it once you're done:

```bash
cd clusters/control/setup
source ../../../.env
sops -d --in-place k0s-cluster.yml
k0sctl apply -c k0s-cluster.yml
sops -e --in-place k0s-cluster.yml
```

### kube-apiserver memory limit

`k0s-cluster.yml` uploads `k0scontroller-gomemlimit.conf` to `/etc/systemd/system/k0scontroller.service.d/gomemlimit.conf` on every node, which sets `GOMEMLIMIT=1100MiB` for `k0scontroller` and so for everything k0s spawns (kube-apiserver, etcd, kubelet). Without it the Go garbage collector lets the apiserver heap reach about twice the live heap (`GOGC=100`), and the apiserver is the largest process on every node.

The value is about 1.4 to 1.9 times the estimated peak live heap of this cluster's apiserver (~770 MiB): a limit closer to the live heap makes the GC run continuously (an A/B on `svc` with 700 MiB against a ~460 MiB peak showed GC CPU spikes four times higher than without the limit). Check `go_cpu_classes_gc_total_cpu_seconds_total` for the apiserver job before lowering it.

`k0sctl apply` only uploads the file: systemd reads it when `k0scontroller` starts. After changing the value, restart the service on one node at a time and wait for the node and etcd to be healthy before the next one:

```bash
ssh root@<node> 'systemctl daemon-reload && systemctl restart k0scontroller'
```

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