# End-to-end tests of the phorge.fr API kinds

Bash, `kubectl`, `jq` and SSH: no other dependency. The suite runs against the **real** `control`
cluster and the **real** Incus cluster (it creates VMs, pulls images, writes OpenFGA tuples) and
removes what it created. It is run by hand, not in CI.

```
./run.sh                 # everything, about an hour (image pulls and VM boots dominate)
./run.sh fast            # admission + guards: server-side dry runs, a few minutes, no Incus change
./run.sh tenant image    # chosen groups; fixtures are created on demand
./run.sh --list          # group names
./run.sh --sweep         # first delete what an interrupted run left behind
E2E_KEEP=1 ./run.sh ...  # do not clean up (for debugging); or --keep
```

Needs: `kubectl` context `control` (override with `E2E_CONTEXT`), `ssh root@10.10.0.1` to an Incus
node (`INCUS_HOST`), and the Crossplane compositions of `overlays/control/controllers/crossplane`
deployed. Optional: `FGA_URL` and `FGA_TOKEN` (an OpenFGA reachable from here) to read the tuples
back from OpenFGA and run real `check` calls in the `access` group.

## Safety

* Everything is named `e2e-<run id>-*` and labelled `e2e.phorge.fr/run`. Nothing else is touched.
* One run at a time (`/tmp/phorge-e2e.lock`).
* The cleanup deletes children first, then the tenants, then waits for the Incus projects to be
  gone (Kubernetes can say "deleted" minutes before Incus does).

## Groups

| Group | Needs | What it covers |
|---|---|---|
| `admission` | API server | Every XRD rule by server-side dry run: bounds, enums, patterns, defaults, name rules, set uniqueness |
| `guards` | controllers | XRs in the wrong namespace are refused and never reach Incus' `default` project; a `t-*` namespace without a tenant |
| `tenant` | Incus | What a Tenant composes: namespace, project limits per plan, every `restricted.*` key, OVN network, profile, owner tuple, 28-character name, odd owner emails, and that the subnets Incus picks are distinct and outside the router's VLANs |
| `image` | Incus, Internet | Pull, fingerprint, aliases, per-project isolation, deletion, an image that does not exist |
| `instance` | Incus, Internet | A running VM end to end (limits, disk, cloud-init key, guest check), stopped and nested VMs, plan quota, disk over quota, missing image |
| `access` | OpenFGA | Membership roles and subjects, duplicates, role change, deletion; ApiKey scopes to tuples, scope add/remove, expiry; optional real `check` calls |
| `network` | Incus, Internet | Addressing, routing, DNS, Internet access, path MTU, what is blocked (other VLANs, router), isolation between tenants, nothing exposed |
| `update` | Incus | Plan, description and owner changes; alias; live cpu, memory, disk, ssh keys; stop/start without recreation |
| `deletion` | Incus | Deleting a tenant with a running VM: order, timing, orphan window; an object removed behind Crossplane's back; an Image still in use |

`PASS`/`FAIL` lines are assertions. `INFO` lines document a behaviour the code does not guarantee
(duplicate tuples, expiry, recreation after an out-of-band delete, the subnets picked): they never
fail the run, but a change in them is worth reading.

## Not covered

* Authorization as Incus enforces it for a real OIDC login (needs Authentik): only the tuples are checked.
* Drift: the provider's poll interval makes "change it in Incus and wait for the revert" too slow.
* Anything the API or console will add (this suite tests the kinds, not an API).
* Concurrency (several tenants created at once), and quota of the shared Ceph pool.
