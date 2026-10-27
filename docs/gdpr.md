# GDPR notes: cookies, third parties and personal data

Working notes for the sign-in (`auth.phorge.fr`, `cap.phorge.fr`) and the rules the frontend will have to follow. Facts marked **checked** were measured on the live sign-in page on 2026-10-27 (headless Chromium, DevTools: cookies, storage and every host contacted). The legal readings come from the CNIL guidance as remembered, they are not legal advice: have a DPO or a lawyer confirm them before they go in a privacy policy.

## Cookies and browser storage

What the sign-in page stores in the browser of a visitor, before and after the captcha (**checked**):

| Name | Where | What it is for | Flags and lifetime |
|---|---|---|---|
| `authentik_session` | cookie, `auth.phorge.fr` | Holds the state of the sign-in flow (a signed token carrying a session id). Set on the first request of the flow, so also for a visitor who never signs in. | `HttpOnly`, `Secure`, `SameSite=None`, session cookie (no `Expires`). The server-side session lasts 12 hours once signed in (`session_duration`). |
| `authentik_csrf` | cookie, `auth.phorge.fr` | CSRF protection of the write calls of the authentik interface. **Not seen** on the sign-in page, only expected once signed in (the settings say a lifetime of about 1 year, `SameSite=Lax`, readable by scripts). Not checked after a sign-in. | to measure |
| `authentik_tab_id` | `sessionStorage` | Identifier of the browser tab, for the interface. Never leaves the browser. | tab lifetime |
| none | Cap (`cap.phorge.fr`) | The captcha sets no cookie and uses no `localStorage` or `sessionStorage`. | |

Reading, to confirm: all of them are strictly necessary (authentication, protection against forgery and bots), which the CNIL exempts from consent. So **no consent banner is needed for the sign-in as it is today**, the information goes in the privacy policy. The exemption is lost the day something non-essential is added (analytics, audience, a support widget): that needs a banner with "reject" as easy as "accept".

Not inventoried yet, because they are administration tools and not meant for end users: Grafana (`grafana_session`), Forgejo, Crossview, Uptime Kuma. Do it when one of them is opened to customers.

## Third parties contacted by the visitor's browser (**checked**)

A request to another host gives that host the visitor's address and browser, even with no cookie. German and French authorities have treated a font or script loaded from a third-party CDN without consent as a transfer of personal data.

| Host | Why | Status |
|---|---|---|
| `avatars.githubusercontent.com` | The logo and the favicon of the brand (`branding_logo`, `branding_favicon` in `blueprint-brand.yml`) | Contacted by every visitor, GitHub is a US company. To fix: host the two images ourselves (a `data:` URI in the blueprint, or authentik media). |
| `cdn.jsdelivr.net` | The widget of Cap loads its WebAssembly (`cap_wasm_bg.wasm`, `hashwx.wasm`) from this CDN by default | Contacted at every sign-in. Cap serves the same files itself under `https://cap.phorge.fr/assets/`, but authentik's captcha stage cannot set the widget's `CAP_CUSTOM_WASM_URL`. Options: serve a copy of `widget.js` patched to point at `/assets/`, or ask Cap/authentik for a setting. |
| `cap.phorge.fr` | The captcha itself | Ours. |

Server side, authentik can also ask Gravatar for an avatar (the network policy of the namespace lets the server reach the internet, and authentik documents `gravatar,initials` as its default avatar mode). A Gravatar request carries a hash of the user's e-mail. Check `AUTHENTIK_AVATARS` and set it to `initials` if nobody needs Gravatar.

## Personal data kept by the sign-in

| Where | What | How long | Notes |
|---|---|---|---|
| authentik database, events | Action, user name, e-mail, **client address**, **user agent**, country and network (GeoIP) | 365 days (`event_retention`) | `gdpr_compliance` is on: the events of a user are deleted with the user. |
| authentik database, reputation | Address, score, country and network of an address that failed a sign-in | Until the entry expires | Used to close the flow to an abusive address. |
| Loki, `{namespace="authentik"}` | The same events as JSON log lines (`Created Event`), the `Updated score` lines (address, typed identifier, score) and the `Sign-in flow started` lines (address, country, network, score, request id), one per start of the flow, so also for visitors who never sign in | 30 days (`retention_period: 720h`) | Includes the raw `context.username`: what a visitor typed in the user name field, which can be a password typed in the wrong field. The password field itself is masked. |
| Loki, `{namespace="traefik"}` | The HTTP audit log of core's Traefik (`docs/http-audit.md`): client **address**, host and path requested (query string dropped), method, status, duration, **user agent**, router and service, country and network of the client | 30 days (`retention_period: 720h`) | Every visitor of a public host is in it, whether or not they sign in. The `Authorization` and `Cookie` headers and the `Referer` are not kept. |
| Discord (alert webhook) | Action, user name, country, request id, nothing else | Discord's own | Minimised on purpose: no address, no e-mail, no browser. The request id finds the full line in Loki. A US processor: record it in the register. |
| Brevo (SMTP relay) | The e-mail address and the content of the mails authentik sends (recovery, notifications) | Brevo's own | French provider, still a processor to list. |
| GeoIP | Nothing leaves the cluster: the lookups are local (authentik uses MaxMind GeoLite2, Alloy the DB-IP lite databases). The only thing fetched from outside is the database files, by the init container of Alloy, which sends nothing about the visitors. | | DB-IP lite is CC BY 4.0: keep the credit "IP Geolocation by DB-IP" where the map is shown. |

## Decisions still to take

1. **Retention of the logs.** 30 days in Loki and 365 days in the database do not match, and neither was chosen against a rule. The CNIL recommends a few months for connection logs (6 months is the figure remembered). As a hosting provider (tenants, VMs) Phorge may also owe the authorities identification and connection data for one year (LCEN, 2021 decree on the data kept by hosting providers). To settle with a lawyer, then set one duration: `limits_config.retention_stream` in `overlays/core/apps/loki/loki.yml` can give `{namespace="authentik"}` its own period without changing the rest of Loki (check the size of the volume first).
2. **The two third-party hosts above.** Fix them, or document the legal basis and the transfer.
3. **A privacy policy and a legal notice**, linked from the sign-in page (the brand has footer links, `branding_footer_links` or the brand's `attributes`, to check). It must say which data is kept, why, for how long and who the processors are (this page is the source).
4. **Rights of the persons.** Access and erasure: the database part is covered by `gdpr_compliance` and the user deletion. For Loki, the delete API is available (`delete_request_store: filesystem`), but there is no procedure written; write it before the first request.
5. **A register of processing** (article 30) with the table above as a start.

## Rules for the frontend

- First-party only: no CDN for scripts, fonts, icons or images. Bundle and serve them from our own hosts. This is the only way not to repeat the two findings above.
- A session or authentication token is strictly necessary, whether it is a cookie or in `localStorage`; the exemption covers storage as much as cookies. Use `HttpOnly`, `Secure`, `SameSite=Lax` (or `Strict`) and the shortest lifetime that works. Anything else is optional and needs consent.
- Any optional cookie or tracker waits for consent: nothing is written or loaded before the visitor answers, "reject all" is as visible as "accept all", the choice is remembered (the CNIL asks to ask again after 6 months at most) and no cookie lives longer than 13 months.
- No analytics, session replay, chat or error-reporting widget from a third party without going through this page first. If one is needed, prefer a self-hosted tool configured to be exempt.
- Do not put personal data in URLs or in client-side logs.
- Links to the privacy policy and the legal notice on every page, the sign-in included.

## Measuring again

After any change to the sign-in (a new stage, a new asset, a new widget), repeat the measure: open the flow in a clean headless Chromium over the DevTools protocol, wait for the captcha, then read `Network.getAllCookies`, `localStorage`, `sessionStorage` and the list of hosts from `Network.requestWillBeSent`. The cookies of a signed-in session are still to measure.
