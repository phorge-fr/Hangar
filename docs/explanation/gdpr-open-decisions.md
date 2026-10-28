---
type: explanation
audience: maintainer deciding how long to keep logs and what to tell visitors
verified: 2026-10-27
---

# GDPR: decisions still to take

The facts are in [the personal data inventory](../reference/gdpr-personal-data.md). These choices are open.

1. **Retention of the logs.** 30 days in Loki and 365 days in the database do not match, and neither was chosen against a rule. The CNIL recommends a few months for connection logs (6 months is the figure remembered). As a hosting provider (tenants, VMs) Phorge may also owe the authorities identification and connection data for one year (LCEN, 2021 decree on the data kept by hosting providers). To settle with a lawyer, then set one duration: `limits_config.retention_stream` in `overlays/core/apps/loki/loki.yml` can give `{namespace="authentik"}` its own period without changing the rest of Loki (check the size of the volume first).
2. **The two third-party hosts above.** Fix them, or document the legal basis and the transfer.
3. **A privacy policy and a legal notice**, linked from the sign-in page (the brand has footer links, `branding_footer_links` or the brand's `attributes`, to check). It must say which data is kept, why, for how long and who the processors are (this page is the source).
4. **Rights of the persons.** Access and erasure: the database part is covered by `gdpr_compliance` and the user deletion. For Loki, the delete API is available (`delete_request_store: filesystem`), but there is no procedure written; write it before the first request.
5. **A register of processing** (article 30) with the table above as a start.
