---
type: how-to
audience: maintainer who edited a plain line of a k0s cluster file
verified: 2026-10-28
---

# Reseal a k0s cluster file after a hand edit

You edited a plain line (a flag, a path) of `clusters/<cluster>/setup/k0s-cluster.yml` and `sops -d` now fails with "MAC mismatch". Sign the file again without changing its layout. The reason is in [How k0sctl apply behaves](../explanation/k0sctl-apply-behavior.md#sops-signs-the-whole-file).

## Before you start

- The age key `age.agekey` at the root of your clone (gitignored).
- The plaintext of the file holds the VRRP password: write it only to a temporary file and delete it at the end.

## Steps

Run from the repository, with `C` set to the cluster:

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

The two `sed`-free edits are manual on purpose: keep the layout of the committed file and take from `/tmp/new.yml` only the `authPass:` line and the whole `sops:` block.

## Check that it worked

The last two commands of the block above: `sops -d` must succeed and `yamllint` must print nothing.

## Undo

`git checkout -- clusters/<cluster>/setup/k0s-cluster.yml` returns to the committed, signed file.
