---
type: how-to
audience: maintainer who changed the sign-in page
verified: 2026-10-27
---

# Measure cookies and third parties on the sign-in

Do this after any change to the sign-in (a new stage, asset or widget), then update [the inventory](../reference/gdpr-personal-data.md).

## Steps

1. Open the flow in a clean headless Chromium over the DevTools protocol.
2. Wait for the captcha.
3. Read `Network.getAllCookies`, `localStorage`, `sessionStorage` and the list of hosts from `Network.requestWillBeSent`.

## Check that it worked

The inventory lists exactly what you read. The cookies of a signed-in session are still to measure.
