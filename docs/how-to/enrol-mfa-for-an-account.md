---
type: how-to
audience: administrator or user who enrols a second MFA device
verified: 2026-10-27
---

# Enrol MFA for an account

MFA is mandatory; the flow proposes the enrolment at the first sign-in. Do this once per account to have a second support, so a lost phone does not lock it.

## Steps


1. Sign in. The enrolment is proposed by the flow itself (for `akadmin` it is the next sign-in).
2. Open `https://auth.phorge.fr/if/user/`, Settings, MFA Devices, and add a **second** support: a passkey on another device, or a passkey and a TOTP app. Then create the static recovery codes and keep them offline. One device is enough to sign in, two is what stops a lost phone from locking the account.
3. Sign out and in again to check that the second factor is asked.

## Check that it worked

Step 3 is the check: the second factor must be asked.

## Related

- [Authentik sign-in hardening](../explanation/authentik-sign-in-hardening.md#mfa)
- [Recover access to Authentik](../how-to/recover-access-to-authentik.md)
