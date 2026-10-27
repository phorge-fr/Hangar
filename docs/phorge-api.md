# Phorge API kinds (`phorge.fr/v1alpha1`)

The resources a tenant of the Phorge cloud is made of. They are Crossplane composite resources (XRs) on the `control` cluster. An API, a console or a Terraform provider only has to create, read and delete these; Crossplane turns them into Incus and OpenFGA objects. The schemas are the contract: the source of truth is the XRD in `overlays/control/controllers/crossplane/` (`xrd-*.yml`), this page explains them.

- [Model](#model)
- [Tenant](#tenant)
- [Image](#image)
- [Instance](#instance)
- [Membership](#membership)
- [What a tenant can and cannot do](#what-a-tenant-can-and-cannot-do)
- [Lifecycle and deletion](#lifecycle-and-deletion)
- [Authorization](#authorization)
- [Not done yet](#not-done-yet)

## Model

```mermaid
flowchart TB
    subgraph sys["namespace phorge-system"]
        tenant["Tenant demo"]
    end
    subgraph ns["namespace t-demo"]
        image["Image"]
        instance["Instance"]
        member["Membership"]
    end
    tenant -->|creates| ns
    tenant -->|composes| project["Incus project t-demo"]
    tenant -->|composes| net["OVN network default"]
    tenant -->|composes| profile["profile phorge"]
    tenant -->|composes| owner["tuple: owner is admin"]
    image -->|composes| iimg["Incus image"]
    instance -->|imageRef| image
    instance -->|composes| ivm["Incus VM"]
    member -->|composes| tuple["OpenFGA tuple"]
```

| Kind | Scope | Lives in |
|---|---|---|
| `Tenant` | Namespaced | `phorge-system` only |
| `Image`, `Instance`, `Membership` | Namespaced | the tenant's namespace `t-<name>` only |

A tenant `demo` is the namespace `t-demo` and the Incus project `t-demo`. Creating an `Image`, `Instance` or `Membership` anywhere else, or a `Tenant` outside `phorge-system`, fails with `Synced=False` and a message that names the namespace. This guard exists because the namespace is used as the Incus project name: an `Instance` in `default` would otherwise target the real `default` project.

Every kind reports the standard Crossplane conditions (`Synced`, `Ready`). `Ready=True` means every composed resource is up.

## Tenant

The isolation and quota boundary. `metadata.name` is the tenant slug: 2 to 28 characters, lowercase letters, digits and hyphens, starting with a letter.

| Field | Type | Rule |
|---|---|---|
| `spec.owner` | string, required, immutable | Email of the owner, the OIDC claim Incus identifies users by. Gets the Incus `admin` role on the project. To hand a tenant over, add a `Membership` with the `admin` role |
| `spec.displayName` | string | Up to 100 characters. Used as the project description |
| `spec.plan` | enum | `small` (default), `medium`, `large` |
| `status.namespace` | string | `t-<name>` |
| `status.incusProject` | string | `t-<name>` |

Plans, enforced by Incus as project limits:

| Plan | VMs | vCPU | Memory | Disk | Networks |
|---|---|---|---|---|---|
| `small` | 1 | 2 | 4 GiB | 20 GiB | 1 |
| `medium` | 3 | 4 | 8 GiB | 100 GiB | 2 |
| `large` | 6 | 8 | 16 GiB | 250 GiB | 3 |

Composes: a Kubernetes namespace, an Incus project, an OVN network `default` of its own on the `UPLINK` (NATed), a profile `phorge` (root disk on the `remote` pool, `eth0` on that network) and the owner's tuple.

```yaml
apiVersion: phorge.fr/v1alpha1
kind: Tenant
metadata:
  name: demo
  namespace: phorge-system
spec:
  owner: alice@example.org
  plan: small
```

## Image

An image pulled into the tenant's project. Instances start from an `Image`, never from a bare image name: an instance created from a remote name makes Incus cache that image in the project outside any managed resource, and the project can then no longer be deleted.

| Field | Type | Rule |
|---|---|---|
| `spec.source.name` | string, required | Name on the remote, e.g. `debian/13/cloud` |
| `spec.source.remote` | string | Default `images` (linuxcontainers.org) |
| `spec.source.type` | enum | `virtual-machine` only (default) |
| `spec.source.architecture` | string | Default `x86_64`, see below |
| `spec.aliases` | list of string | Optional Incus aliases |
| `status.fingerprint` | string | Set once pulled |

The architecture default matters: the Incus provider runs on the arm64 control nodes and Incus otherwise pulls the image for the client's architecture, which no compute node can run. Pulling a VM image takes a few minutes.

## Instance

A virtual machine in the tenant's project.

| Field | Type | Rule |
|---|---|---|
| `spec.imageRef.name` | string, required | An `Image` of the same tenant |
| `spec.cpu` | integer | 1 to 16, default 1 |
| `spec.memoryMiB` | integer | 256 to 65536, default 1024 |
| `spec.diskGiB` | integer | 1 to 500, default 10 |
| `spec.running` | boolean | Default `true` |
| `spec.nesting` | boolean | Default `false`. Allows virtualization or containers inside the VM |
| `spec.sshPublicKeys` | list of string | Injected with cloud-init, so the image must be a `cloud` variant |
| `status.state` | string | Incus state, e.g. `Running` |
| `status.ipv4` | string | Address on the tenant's network |

The per-instance bounds are the XRD's. The plan's totals are enforced on top by the project: a second VM on a `small` tenant is refused by Incus with `Reached maximum number of instances`, and the instance stays `Synced=False` with that message.

## Membership

Gives a user or a group a role on the tenant. The tenant is the namespace the `Membership` lives in.

A `Membership` cannot be edited: changing the subject or the role is refused. An OpenFGA tuple cannot be changed in place and the provider refuses to destroy one, so an edit would leave the old right granted while everything reads `Ready`. Delete the `Membership` and create another.

| Field | Type | Rule |
|---|---|---|
| `spec.subject.kind` | enum, required | `User` or `Group` |
| `spec.subject.name` | string, required | The user's email, or the group name |
| `spec.role` | enum, required | `admin`, `operator`, `user`, `viewer` |

A `Membership` writes two OpenFGA tuples:

| Store | Tuple | Why |
|---|---|---|
| `iaas` (the one Incus authorizes against) | the subject is `viewer` of the Incus project, **whatever the role** | The Incus UI (`iaas.phorge.fr`) is read-only. Crossplane owns every Incus object and reconciles back anything changed by hand |
| `phorge-api` | the subject has the real role on `tenant:<name>` | This is what the Phorge API checks before it writes |

| Role | Meaning for the API |
|---|---|
| `admin` | Everything on the tenant, including memberships |
| `operator` | Manage instances, images (and read the rest) |
| `user` | Create and use instances |
| `viewer` | Read-only |

There is one `Membership` per subject in a tenant: the tuples are named after a hash of the subject, so a second `Membership` for the same user or group (with any role) is not composed and stays `Ready=False`, instead of silently sharing, and on deletion removing, the tuple of the first. To change a role, delete the `Membership` and create another. A `Membership` for the tenant's owner is refused: the owner already has the `admin` role from the `Tenant`.

Like every kind that lives in a tenant namespace, it is only composed if a `Tenant` of that name exists in `phorge-system`: a namespace named `t-<x>` created by hand gets nothing, so it cannot be used to grant rights on a future tenant.

## ApiKey

A personal access token: it lets a person's scripts and tools (OpenTofu, CI, a CLI) call the Phorge API as that person. It belongs to a user, not to a tenant, so every `ApiKey` lives in the namespace `phorge-keys`, named after the id of the key (`phk_<id>_<secret>`). It stores the SHA-256 of the secret, never the key.

| Field | Type | Rule |
|---|---|---|
| `spec.owner` | email, required, immutable | The user the key acts as. Recorded by the API from the token of the person who creates it |
| `spec.hash` | string, required, immutable | SHA-256 of the secret, 64 lowercase hex characters. A secret is not rotated: create another key |
| `spec.scopes` | set, required | Among `tenants:read`, `tenants:write`, `instances:read\|write`, `images:read\|write`, `memberships:read\|write` |
| `spec.expiresAt` | date-time | The API requires it, at most 366 days ahead; the XRD does not |
| `spec.displayName` | string | At most 100 characters |
| `status.keyId` | string | The name of the object, the id in the key |
| `status.expired` | boolean | True once `expiresAt` has passed |

**A key is its owner, within its scopes.** Nothing is written to OpenFGA for it: at every request the API checks that the scope covers the action, then asks OpenFGA about the owner (`user:<owner>`). A key therefore never exceeds the person it belongs to, even if their rights change after the key was made. `tenants:read` reads the tenants the owner sees (all of them for a platform administrator), `tenants:write` creates, resizes and deletes tenants (platform administrators only) and reads them too. The other scopes are the ones that already existed, now on every tenant the owner has a right on. The `key_*` relations of the OpenFGA model are no longer written (the model is immutable and was left as it is).

**Platform administrator.** A token carries the groups of its user, a key does not: the API asks Authentik whether the owner is a member of `phorge-platform-admins`, with the token of a service account that can read that one group and nothing else (the answer is kept for a minute). A key stops being an administrator's within a minute of its owner leaving the group.

**Who manages keys.** Only a person signed in with Authentik: a key cannot create, read or delete keys. For now only the platform administrators create and change them; anyone lists and revokes their own. `expiresAt` is enforced by the API at every request, to the second; `status.expired` is only what the list shows.

## What a tenant can and cannot do

The project is deny-by-default: `restricted=true` and every `restricted.*` key set explicitly, so a changed default in a later Incus release cannot silently open something.

| Allowed | Blocked |
|---|---|
| VMs, with optional nesting | Containers (`limits.containers=0`) |
| Disks on the `remote` pool, managed NICs | GPU, PCI, USB, proxy, infiniband, unix devices |
| Several OVN networks, up to the plan, on the `UPLINK` | Choosing a cluster node (placement is Incus's) |
| Data volumes, snapshots, backups | Forwards and load balancers (no public exposure yet) |
| Images through the `Image` kind | Custom image upload |

Traffic from a tenant leaves through the `comp-ns` VLAN. The router drops traffic between Phorge networks (`drop-phorge-to-phorge` in the Network repository), so tenants reach the Internet but not the other VLANs. That is enforced by the router, not by Incus.

## Lifecycle and deletion

- **Delete in the foreground.** Deleting an XR in the default (background) mode removes the object at once while its composed resources and the Incus objects last for up to a minute or two: a `Tenant` was gone after 1 s, its resources after 58 s. With `propagationPolicy: Foreground` (`kubectl delete --cascade=foreground`) the object stays until everything it composed is gone, so its absence is a real completion signal. An API should always delete this way and treat "not found" as "deleted".
- **An `Instance` whose first start failed is stuck and must be deleted and created again.** Incus creates the VM, the start then fails (for instance "incompatible with secureboot", see `spec.secureBoot`), and the provider keeps the resource as failed: every later reconcile wants to destroy and recreate it, which `prevent_destroy` refuses. `status.problems` then shows the original error as well as the `prevent_destroy` one.
- **An `Image` used by an `Instance` cannot be deleted.** The request is refused ("in-use by 1 usage(s)"). The refusal is remembered and replayed: the `Image` goes by itself, a few seconds after the last `Instance` that uses it, without a second delete.
- `status.problems` on every kind says what is wrong with the composed resources (the Incus or OpenFGA error), empty when everything is up. `Ready` now needs the composed resources to be `Ready` **and** `Synced`.

- Deleting an `Instance` or an `Image` removes the Incus object.
- Deleting a `Tenant` deletes its namespace, which cascades to every `Image`, `Instance` and `Membership` in it, then the network, the profile, the tuple and finally the project. Incus refuses to delete a non-empty project, so the project is retried until its contents are gone. The projects are never force-destroyed.
- Deleting a `Tenant` destroys the VMs it contains. An API should ask for confirmation.

## Authorization

Users authenticate with Authentik (OIDC). Incus identifies them by the `email` claim, so the email is the key of every tuple, and the Authentik enrollment flow must make it mandatory. Tuples are written by Crossplane in two OpenFGA stores:

- `iaas` (`overlays/control/resources/openfga/store.yml`): the one Incus enforces. Users and groups are only `viewer` there: the Incus UI is read-only for everybody, the tenant owner included. Crossplane reconciles an Incus object back as soon as it is changed by hand, and a VM deleted in Incus is recreated blank.
- `phorge-api`: the roles the Phorge API checks (`can_read_*`, `can_write_*`). Writing goes through the API. An API key writes nothing there: it acts as its owner.

No users or groups are stored in Crossplane: Authentik owns identities.

## Not done yet

- **`Expose`** (publishing an instance), forward address blocks per tenant.
- **Image source restriction.** `restricted.images.servers` cannot be set: the provider sends the image server without a scheme and Incus refuses every pull. The `Image` kind is the only gate.
- **Network addressing.** Tenant networks get the subnet Incus picks (`ipv4.address: auto`), which Incus is relied on to keep distinct from its other networks. It knows nothing of the router VLANs, so a subnet inside `10.1` to `10.5` or `10.10` to `10.12` is possible, if unlikely: the e2e suite checks it, nothing prevents it. The provider only returns the keys that were declared, not the address Incus picked, so a `Tenant` cannot check it itself: whatever creates tenants should read `ipv4.address` of the `default` network from Incus once the tenant is `Ready`, and recreate the tenant if it lands in one of those ranges.
- **Per-tenant network isolation inside a tenant, ACLs, metering.**
