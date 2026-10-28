# 0007: Deny-all-by-default policy for tenant projects

Status: accepted, encoded in the `Tenant` composition. Check these values before changing tenant limits.

## Decision

Each `Tenant` gets an Incus project with everything denied except what is needed:

- Instances: virtual machines only; nesting allowed in VMs only.
- Network: several OVN networks per tenant (limit per plan), uplinks restricted. Egress to the Internet is free but not to internal networks, which is enforced by the router, not by an Incus ACL.
- Images: only the public `linuxcontainers.org` source, through the managed `Image` kind; no upload.
- Direct Incus access for tenant users is read-only; writes go through the Phorge API.
- Storage: data volumes, snapshots and backups allowed; no S3 buckets for now.
- Devices: GPU, PCI, USB, unix devices and InfiniBand blocked; disk and NIC are `managed`.
- Plans (instances / vCPU / memory GiB / disk GiB / networks): S 1/2/4/20/1, M 3/4/8/100/2, L 6/8/16/250/3.
- Placement is imposed by the platform.
- Public exposure (`Expose`) is wanted but deferred ([0005](0005-no-ingress-outside-the-cluster.md)).

## Related decisions

- Authentik owns authentication and identities; OpenFGA, through the `Tenant` and `Membership` kinds, owns authorization. There is no `User` or `Client` kind.
- API keys are personal: owned by a user, acting as that user within explicit scopes, expiring within a year; only a person with an Authentik token manages keys.
- `forceDestroy` on an Incus `Project` is for throwaway spikes only; compositions keep it `false`. Image pulls are a managed `Image`, never left to an `Instance`, because an unmanaged pull makes the project non-empty and blocks its deletion.
