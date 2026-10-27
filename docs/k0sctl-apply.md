# k0sctl apply: what it really does, and how to run it

`k0sctl` is the tool of this repository for the k0s clusters (`clusters/<cluster>/setup/k0s-cluster.yml`). `clusters/k0sctl-apply.sh <cluster>` runs it with the guard rails below. Everything here was measured with `k0sctl apply --dry-run` (v0.31.0) and its `--debug` trace on 2026-10-27; the live behaviour of the first real apply is to be added to this page.

## What the dry run showed

On `svc`, with the config of Git, **before any change of ours** (the config of the GOMEMLIMIT commit gives the same), `k0sctl apply` plans for each of the three controllers: upload the files of `files:`, then *stop the k0s service, reinstall it and start it*, with the message "k0s will be upgraded", although k0s is already in the version of the config. The reason is in the debug trace:

```
file modtimes for .../k0scontroller-gomemlimit.conf differ (2026-10-27 02:16:04 +0100 CET vs 2026-10-24 18:58:06 +0200 CEST)
marked for upgrade because file was changed for upload .../k0scontroller-gomemlimit.conf
```

- **k0sctl compares the modification date of every file of `files:` with the remote one**, not its content. When they differ the host is marked for upgrade and its controller service is restarted. After an apply the remote file carries the date of the local one, so the next apply changes nothing.
- The GOMEMLIMIT drop-in (issue #203) was put on the nodes by hand on 2026-10-24: its remote date is not the one of the local file, so **the first `k0sctl apply` that carries it restarts the controllers of every cluster**. That is the first test of the drop-in with k0sctl, and it is what the issue asks for. It is also very likely what cut the clusters in issue #70.
- **The date of a file in a Git checkout is the date of the checkout** (or of the last pull that changed it): on a fresh clone, or after changing branch, every uploaded file looks modified and the controllers are restarted at the next apply, whatever the content. `clusters/k0sctl-apply.sh` sets the date of the uploaded files to the date of their last commit before it runs, so it is the same on every machine and every checkout.
- `--concurrency` is 30 hosts at once by default: the script uses `--concurrency 1`.

## The script

```
clusters/k0sctl-apply.sh svc --dry-run     # reads only: the plan, nothing else
clusters/k0sctl-apply.sh svc               # asks, then applies
```

Order: `svc`, then `core`, then `control` (the least critical first), one cluster at a time and the result of each looked at before the next. Do not run it on `control` while the end-to-end tests of the API run.

What it does around `k0sctl apply`:

1. The config and every file it uploads must be the ones of `origin/main` (a dry run only warns).
2. The config is decrypted with SOPS into a temporary `0600` copy next to the real one (k0sctl needs the paths of `files:` relative to it) and removed at the end: the tracked file is not touched, there is no re-encryption and no diff. It is the same as the `sops -d --in-place` / `sops -e --in-place` of the READMEs, without the churn.
3. The dates of the uploaded files are set to their last commit (above).
4. The plan of `k0sctl apply --dry-run` is printed, then it asks. Nothing starts without a yes.
5. It creates `/var/lib/k0s-audit` on the nodes (the drop-in that creates it is read at the restart, too late for the first start) and copies each `/etc/k0s/k0s.yaml` to `k0s.yaml.before-k0sctl`.
6. While `k0sctl apply --concurrency 1` runs, the API of the cluster (`/readyz` through the control plane address) and one public address (`git.phorge.fr`, `auth.phorge.fr`, `api.phorge.fr`) are probed every second.
7. Afterwards it prints the windows where a probe failed, the containers that restarted (the symptom of issue #70), and for each node: Ready, the new API server process, the audit flags and file, the policy checksum and the `GOMEMLIMIT` of the API server process.

If k0sctl fails: the log is `/tmp/k0sctl-apply-<cluster>-<date>.log`, the config of every node before the apply is `/etc/k0s/k0s.yaml.before-k0sctl`, and the other controllers keep the cluster up.

## SOPS and the plain lines of `k0s-cluster.yml`

SOPS signs the **whole** file (the MAC covers every value, encrypted or not). Editing a plain line by hand (a flag, a path) makes `sops -d` fail with "MAC mismatch": it happened with the audit flags added in #246, which made the three files unreadable by the procedure of the READMEs until they were resealed. `sops -e` signs again but rewrites the file with 2-space indents under lists, which `.yamllint.yml` refuses. `clusters/sops-reseal.sh <file>` keeps the committed layout and carries over only the encrypted values and the `sops:` block. Use it after any hand edit of these files, and check with `sops -d <file> > /dev/null`.
