---
status: accepted
date: 2026-10-15
decision-makers: l-nmch
---

# Deny-all-by-default policy for tenant projects

## Context and problem statement

Each `Tenant` gets an Incus project. Which capabilities do tenants get, and which are denied?

## Decision drivers

* Default deny: allow only what is needed.
* The Phorge API is the only write path for tenant users.

## Considered options

* Deny by default, allow listed capabilities.
* Allow by default, deny listed capabilities.

## Decision outcome

Chosen option: "deny by default", encoded in the `Tenant` composition. Check these values before changing tenant limits:

* Instances: virtual machines only; nesting allowed in VMs only.
* Network: several OVN networks per tenant (limit per plan), uplinks restricted. Egress to the Internet is free but not to internal networks, which the router enforces, not an Incus ACL.
* Images: only the public `linuxcontainers.org` source, through the managed `Image` kind; no upload.
* Direct Incus access for tenant users is read-only; writes go through the Phorge API.
* Storage: data volumes, snapshots and backups; no S3 buckets for now.
* Devices: GPU, PCI, USB, unix devices and InfiniBand blocked; disk and NIC `managed`.
* Plans (instances / vCPU / memory GiB / disk GiB / networks): S 1/2/4/20/1, M 3/4/8/100/2, L 6/8/16/250/3.
* Placement is imposed by the platform. Public exposure (`Expose`) is deferred ([0005](0005-no-ingress-outside-the-cluster.md)).

### Consequences

* Good, because a tenant cannot reach beyond its plan.
* Bad, because each new capability needs a decision and a composition change.

## Pros and cons of the options

### Deny by default

* Good, because the safe state is the default.
* Bad, because more work per feature.

### Allow by default

* Good, because fast.
* Bad, because a missed denial is a breach.

## More information

* Authentik owns authentication and identities; OpenFGA, through the `Tenant` and `Membership` kinds, owns authorization. There is no `User` or `Client` kind.
* API keys are personal: owned by a user, acting as that user within explicit scopes, expiring within a year; only a person with an Authentik token manages keys.
* `forceDestroy` on an Incus `Project` is for throwaway spikes only; compositions keep it `false`. Image pulls are a managed `Image`, never left to an `Instance`, because an unmanaged pull makes the project non-empty and blocks its deletion.
