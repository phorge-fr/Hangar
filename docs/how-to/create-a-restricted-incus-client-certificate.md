---
type: how-to
audience: operator who creates or replaces the Incus client certificate of Crossplane
verified: 2026-11-04
---

# Create a restricted Incus client certificate

Give `provider-incus` a client certificate that can do what Crossplane needs and cannot administer the Incus server. An unrestricted trusted certificate has full access to Incus. A restricted certificate that Incus routes to its authorization scriptlet has only what the scriptlet allows: it can create projects and use the objects of the projects named `t-*`, and nothing else.

The rule is a script inside Incus, not a set of OpenFGA tuples. Crossplane holds the OpenFGA key, which cannot be limited to one store or one object ([Hangar#300](https://github.com/phorge-fr/Hangar/issues/300)): rights written as tuples would be rights that Crossplane can give itself.

## Before you start

- A clone of this repository with the age key of the maintainers, and a clone of [phorge-fr/Ansible](https://github.com/phorge-fr/Ansible) with its vault password.
- `openssl`, `sops` and `curl` on your machine.
- The new certificate does not replace the old one until step 5, so Crossplane keeps working while you prepare.

## Steps

1. Generate a key pair on your machine. The private key never goes on a node and never in the Ansible repository:

   ```bash
   openssl ecparam -genkey -name secp384r1 -noout -out client.key
   openssl req -new -x509 -key client.key -sha384 -days 3650 \
     -subj "/CN=crossplane-provider-incus@control" -out client.crt
   openssl x509 -in client.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
   ```

   The last command prints the fingerprint that Incus calls the user of the certificate. Note it.

2. In the Ansible repository, put the public certificate (`client.crt`) and the fingerprint in `incus_crossplane_client_certificate` and `incus_crossplane_client_fingerprint`, in `inventories/production/group_vars/compute.yml`, and run `ansible-playbook playbooks/configure-compute.yml`. The playbook trusts the certificate with `--restricted`, loads the scriptlet, and routes restricted certificates to it. It checks that the fingerprint is the one of the certificate. Do not run `incus config trust add-certificate` by hand: a hand change must be reconciled by the playbook.

3. Check, from your machine, that the certificate is limited. These calls change nothing:

   ```bash
   curl -sk -o /dev/null -w '%{http_code}\n' --cert client.crt --key client.key https://iaas.phorge.fr/1.0/projects/t-check
   curl -sk -o /dev/null -w '%{http_code}\n' --cert client.crt --key client.key https://iaas.phorge.fr/1.0/projects/default
   curl -sk --cert client.crt --key client.key https://iaas.phorge.fr/1.0/certificates
   ```

   The first prints `404`: the scriptlet authorizes a read in a `t-*` project even when it does not exist yet, which is what the provider does before it creates. The second prints `403`, and the third lists no certificate.

4. Put the key pair in the Secret `provider-incus-creds`. Never decrypt the tracked file in place:

   ```bash
   export SOPS_AGE_KEY_FILE=$PWD/age.agekey
   sops -d overlays/control/controllers/crossplane/provider-incus-secret.yml > "$SCRATCH/plain.yml"
   ```

   In `$SCRATCH/plain.yml`, replace `client_cert` and `client_key` in the JSON of `stringData.credentials` and keep `address` and `accept_remote_certificate`. Then encrypt and check:

   ```bash
   sops -e --filename-override overlays/control/controllers/crossplane/provider-incus-secret.yml \
     "$SCRATCH/plain.yml" > overlays/control/controllers/crossplane/provider-incus-secret.yml
   sops -d overlays/control/controllers/crossplane/provider-incus-secret.yml | diff - "$SCRATCH/plain.yml"
   ```

   Also check that the fingerprint of the decrypted `client_cert` is the one of step 1 and that `client_key` matches it (`openssl x509 -pubkey` equals `openssl pkey -pubout`). Delete `$SCRATCH` afterwards: it holds the old and the new private key.

5. Switch Crossplane in this order, so that nothing breaks:
   1. Run the Ansible playbook of step 2 first: the certificate must be trusted before Crossplane presents it.
   2. Merge the pull request that changes the Secret. Flux applies it.
   3. Check that Crossplane works with the new certificate (next section).
   4. Remove the old unrestricted certificate from the Ansible inventory and the cluster: `incus config trust remove <its fingerprint>`.

## Check

- A `Tenant` reconciles `Ready`, which means its `Project`, `Network`, `Profile`, `Image` and `Instance` were created and observed with the new certificate. The end-to-end suite in `tests/e2e` does it for every kind.
- A refused request shows in the Incus log as `restricted client refused`, followed by the object and the entitlement. A new kind of resource that the provider needs shows up there first.
- The certificate cannot administer the server: creating a storage pool, editing the server configuration or reading the `default` project returns `403`.

## Undo

- Back to the old certificate: put the old key pair back in the Secret, or revert the pull request. While the old certificate is still trusted, nothing else is needed.
- Remove the new certificate: delete it from the Ansible inventory and run `incus config trust remove <fingerprint>`.
- Stop the routing: remove `authorization.client.tls-restricted` from `incus_init_shared_config` and run `incus config unset authorization.client.tls-restricted`. A restricted certificate then goes back to the project-list authorizer.
