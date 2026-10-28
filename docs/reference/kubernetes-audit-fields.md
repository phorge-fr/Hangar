---
type: reference
audience: anyone querying the Kubernetes audit log in Loki
verified: 2026-10-28
---

# Kubernetes audit log: queries and fields

The API server writes the log and Alloy ships it to Loki; [how it works](../explanation/kubernetes-audit-log.md).

## Fields

The dashboard reads `{job="k8s-audit"} | json`. The fields are `user_username`, `sourceIPs_0`, `userAgent`, `verb`, `objectRef_resource`, `objectRef_namespace`, `objectRef_name`, `objectRef_subresource`, `objectRef_apiGroup`, `responseStatus_code`, `requestURI`.

## Queries

```
{job="k8s-audit", cluster="core"} | json | verb=~"create|update|patch|delete" | user_username !~ "system:serviceaccount:.*"
{job="k8s-audit"} | json | responseStatus_code=~"401|403"
{job="k8s-audit"} | json | objectRef_resource="secrets" | user_username !~ "system:serviceaccount:flux-system:.*"
```
