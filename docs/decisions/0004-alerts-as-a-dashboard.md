# 0004: Show alerts in a dashboard, keep the Prometheus rules

Status: accepted (Grafana alerting experiment reverted).

## Context

Grafana (13.2.2 on `core`, kube-prometheus-stack 91.4.1) was considered as the place to manage alerts.

## What was verified

- The 155 rules shipped by the chart are evaluated by Prometheus; Grafana lists them read-only and notifies only for its own Grafana-managed rules. The provisioned Alertmanager data source is `implementation: prometheus` with `handleGrafanaManagedAlerts: false`.
- Prometheus cannot push to Grafana's built-in Alertmanager (`POST /api/alertmanager/grafana/api/v2/alerts` returns HTTP 400 even for a minimal payload).
- Grafana can list those rules, read the Alertmanager's alerts, and create and expire silences, but cannot edit or pause a Prometheus-evaluated rule nor write the configuration of a Prometheus-implementation Alertmanager. Contact points stay in `alertmanager.config` in Git.
- File-provisioned Grafana rules are not deleted when their file disappears; removal needs a provisioning file with `deleteRules`.
- Eight of ten rules written for Grafana duplicated the chart's.

## Decision

Do not recreate rules that the chart already ships. A dashboard "Active alerts" (tables per severity, built from the `ALERTS` and `ALERTS_FOR_STATE` series) is enough. Receivers, `cluster` in `group_by`, inhibit rules and silence persistence are tracked as normal issues. The experiment was reverted in the repository and on the cluster.
