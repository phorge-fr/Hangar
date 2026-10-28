# k0sctl apply: what it really does

`k0sctl` is the tool of this repository for the k0s clusters (`clusters/<cluster>/setup/k0s-cluster.yml`). The procedure to run it is in the README of each cluster (`clusters/<cluster>/setup/README.md`, "Deploy the cluster, or apply a change to it"). This page says what the tool does and why that procedure is built the way it is. It was measured with `k0sctl apply --dry-run` and `--debug` (v0.31.0), then with real applies, on 2026-10-27 and 28.

## The rule that matters: the date of the files, not their content

For every file of `files:` (the GOMEMLIMIT drop-in, the audit policy, the audit directory drop-in), k0sctl compares the **modification date** with the one of the remote file. When they differ the host is "marked for upgrade", and for every host marked it will *stop the k0s service, reinstall it and start it*, even when k0s is already in the version of the config ("k0s will be upgraded"). The `--debug` trace says it:

```
file modtimes for .../k0scontroller-gomemlimit.conf differ (2026-10-27 02:16:04 +0100 CET vs 2026-10-24 18:58:06 +0200 CEST)
marked for upgrade because file was changed for upload .../k0scontroller-gomemlimit.conf
```

- After an apply, k0sctl sets the date of the remote file to the date of the local one ("set timestamp"), so a second apply changes nothing.
- The GOMEMLIMIT drop-in (issue #203) had been put on the nodes by hand, so its remote date was not the local one: **the first apply that carried it restarted the controllers of every cluster**. That is the first test of the drop-in with k0sctl, and very likely what cut the clusters in issue #70.
- **The date of a file in a Git checkout is the date of the checkout** (or of the last pull that changed it). On a fresh clone, or after changing branch, every uploaded file looks modified and the next apply restarts every controller, whatever the content. This is why the procedure starts by setting the date of the uploaded files to the date of their last commit: the same date on every machine and every checkout.
- k0sctl configures 30 hosts at once by default. `--concurrency 1` makes it one host at a time. Within the phase "Upgrade controllers" it also waits for each k0s service to start before the next host.
- `k0sctl apply --dry-run` (experimental, v0.31) reads only and prints what it would do: use it, and read "k0s will be upgraded" as "this node's API server will be down for 30 to 90 seconds".

## What was measured

| Cluster | Date | k0sctl | API probe (`/readyz` through the control plane address) | Public address | Containers restarted | `GOMEMLIMIT` of the API server process |
|---|---|---|---|---|---|---|
| `svc` | 2026-10-28 | 261 s, controllers one after the other | 13 windows of failure, almost all 1 s (two of 4 s) | one window of 25 s (`git.phorge.fr`) | 4, once each (`csi-nfs-controller` x2, `kube-state-metrics`, `cilium-operator`) | 850 MiB on the 3 nodes |
| `core` | 2026-10-28 | 117 s | none | none (`auth.phorge.fr`) | 1 (`cilium-operator`) | 900 MiB on the 3 nodes |
| `control` | 2026-10-28 | the three controllers one after the other, a minute apart (10:39, 10:40, 10:41) | not kept | not kept | 1 (`cilium-operator`) | 1100 MiB on the 3 nodes |

Prometheus saw no failed scrape of the API servers of `control` during the apply (its interval is too coarse for a cut of a few seconds, so it proves nothing). The audit flags, the policy checksum (the one of Git) and a written audit file were checked on every node at the same time. `svc` had been configured by hand for the audit the evening before; `k0sctl apply` brought it back to what Git says.

## SOPS and the plain lines of `k0s-cluster.yml`

SOPS signs the **whole** file: the MAC covers every value, encrypted or not. Editing a plain line by hand (a flag, a path) makes `sops -d` fail with "MAC mismatch". It happened with the audit flags added in #246, which made the three files unreadable by the procedure of the READMEs until they were resealed (#250). `sops -e` signs again but rewrites the file with 2-space indents under lists, which `.yamllint.yml` refuses, so the committed layout has to be kept and only what SOPS changes carried over. After a hand edit of a plain line, from the directory of the cluster:

```bash
C=svc                                        # the cluster
REPO=$(git rev-parse --show-toplevel); SETUP=$REPO/clusters/$C/setup
export SOPS_AGE_KEY_FILE="$REPO/age.agekey"
sops -d --ignore-mac "$SETUP/k0s-cluster.yml" > /tmp/plain.yml                       # the plaintext, whatever the MAC says (it holds the VRRP password: delete it after)
sops -e --filename-override "$SETUP/k0s-cluster.yml" /tmp/plain.yml > /tmp/new.yml   # signed again, laid out the SOPS way
# in k0s-cluster.yml, keeping its layout: replace the `authPass:` line by the one of /tmp/new.yml,
# and the whole `sops:` block (age enc, lastmodified, mac, version) by the one of /tmp/new.yml
sops -d "$SETUP/k0s-cluster.yml" > /dev/null && yamllint -c "$REPO/.yamllint.yml" "$SETUP/k0s-cluster.yml"
rm /tmp/plain.yml /tmp/new.yml
```

The paths of `src:` in `files:` are relative to the directory of the config (`../../audit-policy.yaml` from `clusters/<cluster>/setup`); the dry run catches a wrong one before anything is touched.
