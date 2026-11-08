---
type: how-to
audience: maintainer rolling out Cap v4 on the core cluster
verified: 2026-11-08
---

# Upgrade Cap to v4

Cap v4 (`capd`) rewrites the server of the sign-in captcha. The manifest in `overlays/core/apps/cap/` is already v4; this page is the order of the operations around the merge. Nothing is done in the dashboard: the API and the repository carry every step.

What a v4 start does to a v3 Valkey, from the Cap [migration guide](https://trycap.dev/guide/capd/migrate-v3-v4.html) and its source:

- the site keys and their settings are kept, but the **secret of each site key is refused** until it is rotated (`/siteverify` fails, so the sign-in captcha fails);
- the sessions and the API keys of v3 are dropped;
- the hourly counters are copied into the new event store, which needs the data volume (`cap-data`, 2 GiB);
- `CORS_ORIGIN`, `ENABLE_ASSETS_SERVER`, `WIDGET_VERSION` and `WASM_VERSION` are copied once into the settings in Valkey, then ignored.

## Before

1. Test the change live with [the live-testing how-to](test-a-flux-change-live.md) (suspend `flux-system` and `apps`, apply `overlays/core/apps/cap/cap.yml`). Measure the memory of the pod with `kubectl top`: DuckDB defaults to 256 MB and the container limit is 384 Mi. Raise the limit or set `DUCKDB_MEMORY_LIMIT` from that measurement, not before.
2. Back up Valkey. It is the only way back to v3:

   ```bash
   kubectl --context core -n cap exec cap-valkey-0 -- valkey-cli SAVE
   kubectl --context core -n cap cp cap-valkey-0:/data/dump.rdb ./valkey-backup-v3.rdb
   ```

   Keep the file outside the repository.

## Roll out

1. Merge the pull request. Flux creates the volume and replaces the pod (the old one stops first, the volume is `ReadWriteOnce`).
2. Read the log: `kubectl --context core -n cap logs deploy/cap`. It lists the site keys whose secret is refused, and the deprecation warnings of the four variables.
3. From here the sign-in captcha is down until the new secret is deployed. Go on without a pause.

## Rotate the secret of the sign-in key

1. Open the API: `kubectl --context core -n cap port-forward svc/cap 3100:3000`.
2. Sign in with the admin key (the `admin-key` of the `cap` secret). The reply carries `session_token` and `hashed_token`; the other calls send `Authorization: Bearer <base64 of {"token": session_token, "hash": hashed_token}>`.
3. Rotate: `POST /server/keys/<site key>/rotate-secret`. The reply is `{"secretKey": "sk-..."}`. Write it to a scratch file readable by you only, never to the terminal.
4. Put it in `overlays/core/apps/authentik/secret-cap.yml`: decrypt to a scratch file, edit, re-encrypt with `sops -e --filename-override`, check that `sops -d` returns what you edited (see `AGENTS.md`). Open the pull request, merge it, and restart `deploy/authentik-server` and `deploy/authentik-worker` so the blueprint reads the new value (`!Env`).
5. Check a real sign-in at `auth.phorge.fr`. The site key itself does not change, so the ingress paths and `blueprint-brand.yml` stay as they are.

The API keys of v3 are not replaced: nothing in the repository uses one. Create one only when something needs it (`POST /server/settings/apikeys`).

## After

- Remove the four deprecated variables from `cap.yml` once the settings are in Valkey, or keep them as the seed of a rebuilt Valkey: with them, a lost Valkey comes back with the same CORS origin and the same widget files. Changing one of these settings later goes through the API (`/server/settings/...`), not through the variable.
- The events (address, user agent, fingerprint) are personal data: see [the GDPR inventory](../reference/gdpr-personal-data.md). Cap keeps them 30 days by default.

## Roll back

Restore the snapshot into Valkey, then set the image back to `tiago2/cap:3.1.17` (v3 ignores the data volume). A secret already rotated on v4 cannot be read by v3: rotate it again there and update `secret-cap.yml`. The secrets you did not touch keep working.

## Related

- [Recover access to Authentik](recover-access-to-authentik.md)
- [Authentik sign-in hardening](../explanation/authentik-sign-in-hardening.md)
