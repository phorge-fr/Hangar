---
status: accepted
date: 2026-09-20
decision-makers: l-nmch
---

# Show alerts in a dashboard and keep the Prometheus rules

## Context and problem statement

Grafana (13.2.2 on `core`, kube-prometheus-stack 91.4.1) was considered as the place to manage alerts. What can it do with the 155 rules the chart ships?

## Decision drivers

* Do not duplicate rules that the chart already ships.
* See the current alerts in one place.
* Keep contact points in Git.

## Considered options

* Grafana-managed alert rules and its built-in Alertmanager.
* Keep the chart's Prometheus rules and Alertmanager, and add an "Active alerts" dashboard.

## Decision outcome

Chosen option: "Prometheus rules plus a dashboard", because Grafana cannot manage them. A dashboard "Active alerts" (tables per severity, from the `ALERTS` and `ALERTS_FOR_STATE` series) is enough. The Grafana alerting experiment was reverted in the repository and on the cluster.

### Consequences

* Good, because no duplicate rules, and contact points stay in `alertmanager.config`.
* Bad, because Grafana cannot edit or pause a rule; silences are the only write.

### Confirmation

The dashboard shows the firing alerts of the Alertmanager, checked headless ([how-to](../how-to/check-a-grafana-dashboard.md)).

## Pros and cons of the options

### Grafana-managed rules

* Good, because one tool.
* Bad, because eight of ten rules written for it duplicated the chart's, and file-provisioned rules are not deleted when their file disappears (a provisioning file with `deleteRules` is needed).

### Prometheus rules plus a dashboard

* Good, because it reuses what exists.
* Bad, because the receivers, `cluster` in `group_by`, inhibit rules and silence persistence are separate pieces of work, tracked as issues.

## More information

* The rules are evaluated by Prometheus. Grafana lists them read-only; its Alertmanager data source is `implementation: prometheus` with `handleGrafanaManagedAlerts: false`.
* Prometheus cannot push to Grafana's built-in Alertmanager: `POST /api/alertmanager/grafana/api/v2/alerts` returns HTTP 400 even for a minimal payload.
* Grafana can list the rules, read alerts, and create and expire silences, but cannot write the configuration of a Prometheus-implementation Alertmanager.
