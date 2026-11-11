# End-to-end tests of the phorge.fr API kinds

Bash, `kubectl`, `jq` and SSH: no other dependency. The suite runs against the **real** `control`
cluster and the **real** Incus cluster (it creates VMs, pulls images, writes OpenFGA tuples) and
removes what it created. It is run by hand, not in CI.

```
./run.sh                 # the smoke tier: admission, guards, tenant
./run.sh standard        # smoke + networks, profiles: stopped VMs and one image pull
./run.sh full            # everything, about an hour (image pulls and VM boots dominate)
./run.sh fast            # admission + guards: server-side dry runs, no Incus change
./run.sh tenant image    # chosen groups; fixtures are created on demand
./run.sh --list          # group names
./run.sh --sweep         # first delete what an interrupted run left behind
E2E_KEEP=1 ./run.sh ...  # do not clean up (for debugging); or --keep
```

Needs: `kubectl` context `control` (override with `E2E_CONTEXT`), `ssh root@10.10.0.1` to an Incus
node (`INCUS_HOST`), and the Crossplane compositions of `overlays/control/controllers/crossplane`
deployed. Optional: `FGA_URL` and `FGA_TOKEN` (an OpenFGA reachable from here) to read the tuples
back from OpenFGA and run real `check` calls in the `access` group.

## Which tier to run

| Tier | Groups | Needs | Run it for |
|---|---|---|---|
| `fast` | `admission`, `guards` | the XRDs and the compositions | a change to an XRD rule or a guard |
| `smoke` (the default) | `fast` + `tenant` | no image, no VM | any change to a composition |
| `standard` | `smoke` + `networks`, `profiles` | one image pull (cached after the first), stopped VMs, no VM boot | a change to the Network, Profile or Instance kind, or to the limits of a tenant |
| `full` | all | VM boots, the Internet | before a release, or when a change touches what runs inside a VM |

Every group tests the definitions that are **on the cluster**, so a run for a pull request needs its XRDs and compositions applied first (the live-testing how-to: Flux suspended, resumed and the cluster back to `main` afterwards). A run against `main` after a merge needs nothing. The time of every group is printed at the end of a run. The figures of the tiers are to be filled from the first runs; the full run of `tenant`, `image`, `instance`, `access`, `network`, `update` and `deletion` took about an hour, which is why it is no longer the default (phorge-fr/Hangar#387, and what takes the time inside the groups is phorge-fr/Hangar#388).

## Safety

* Everything is named `e2e-<run id>-*` and labelled `e2e.phorge.fr/run`. Nothing else is touched.
* One run at a time (`/tmp/phorge-e2e.lock`).
* The cleanup deletes children first, then the tenants, then waits for the Incus projects to be
  gone (Kubernetes can say "deleted" minutes before Incus does).

## Groups

| Group | Needs | What it covers |
|---|---|---|
| `admission` | API server | Every XRD rule by server-side dry run: bounds, enums, patterns, defaults, name rules, set uniqueness |
| `guards` | controllers | XRs (tenants, images, networks, instances, memberships, keys) in the wrong namespace are refused and never reach Incus' `default` project; a `t-*` namespace without a tenant |
| `tenant` | Incus | What a Tenant composes: namespace, the one set of limits (2 VMs, 2 vCPU, 4 GiB, 128 GiB, 2 networks) whatever the deprecated plan says, two networks allowed and a third refused, every `restricted.*` key, the three profiles s, m and l and no network, owner tuple, 28-character name, odd owner emails |
| `image` | Incus, Internet | Pull, fingerprint, aliases, per-project isolation, deletion, an image that does not exist |
| `instance` | Incus, Internet | A running VM end to end (limits, disk, network device, cloud-init key, guest check), stopped and nested VMs, disk over the limit, missing image |
| `sizes` | Incus, Internet | An instance from a profile (what Incus gets, what the guest gets), a profile above the limits, a profile that does not exist, from custom values to a profile in place |
| `profiles` | Incus | The Profile kind: a profile the user makes (in Incus, in place, from it an instance), its settings (secure boot and keys, never nesting) taken by an instance that does not say its own and overridden by one that does, refused deletion while an instance has it and its replay, the names that are taken, a profile above the limits |
| `access` | OpenFGA | Membership roles and subjects, duplicates, role change, deletion; ApiKey (opt-in, `E2E_APIKEYS=1`): service account, one tuple per tenant and scope, expiry in OpenFGA, deletion; optional real `check` calls |
| `networks` | Incus | The Network kind: deployed by the user, NAT, in-place change, the limit of 2 networks, subnets across tenants, refused deletion while a VM uses it and replay, an instance on a network that does not exist |
| `network` | Incus, Internet | Addressing, routing, DNS, Internet access, path MTU, what is blocked (other VLANs, router), isolation between tenants, nothing exposed |
| `update` | Incus | The deprecated plan changes no limit, description and owner changes; alias; live cpu, memory, disk, ssh keys; stop/start without recreation |
| `deletion` | Incus | Deleting a tenant with a running VM: the namespace waits for its children, order, timing, orphan window; an object removed behind Crossplane's back; an Image still in use |

`PASS`/`FAIL` lines are assertions. `INFO` lines document a behaviour the code does not guarantee
(duplicate tuples, expiry, recreation after an out-of-band delete, the subnets picked): they never
fail the run, but a change in them is worth reading.

## Not covered

* Authorization as Incus enforces it for a real OIDC login (needs Authentik): only the tuples are checked.
* Drift: the provider's poll interval makes "change it in Incus and wait for the revert" too slow.
* Anything the API or console will add (this suite tests the kinds, not an API).
* Concurrency (several tenants created at once), and quota of the shared Ceph pool.
