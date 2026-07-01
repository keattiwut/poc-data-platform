Status: ready-for-agent

# Observability: Prometheus + Grafana + Loki + Teams alerting

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Implement the full observability stack from ADR-0008. This issue is only blocked by infra bootstrap and can run in parallel with the payment-domain issues (02-07).

Wire Prometheus to scrape the native metrics endpoints already exposed by Airflow, ClickHouse, and MinIO, and build Grafana dashboards for system/infra health — kept deliberately separate from Superset, which stays scoped to business BI. Deploy Grafana Loki for centralized, searchable logs across all services, correlated with Prometheus metrics by time (the "PLG stack").

Configure alert routing to Microsoft Teams via two channels by severity, using the exact definitions recorded in `CONTEXT.md`: **Critical** (extraction task failed, dbt build failed entirely, a warehouse/service unreachable, or a dbt error-severity test failed) and **Warning** (everything else non-blocking — a dbt warn-severity test, a freshness check nearing but not past threshold, disk/resource usage trending up). Wire this to fire off of both Prometheus/Alertmanager alerts and Airflow task failure callbacks.

Write a short runbook per common failure mode (Airbyte sync failed, dbt build failed, ClickHouse unreachable, at minimum) and link each from its corresponding alert message — there's no formal on-call rotation, so a responder needs to be able to act without prior context.

## Acceptance criteria

- [ ] Prometheus scrapes Airflow, ClickHouse, and MinIO metrics; Grafana dashboards visualize system/infra health separately from Superset
- [ ] Loki aggregates logs from all services, queryable/correlatable alongside Grafana's metrics dashboards
- [ ] Alerts route to two distinct Teams channels by severity, matching the Critical/Warning definitions in `CONTEXT.md` exactly
- [ ] Both Prometheus/Alertmanager alerts and Airflow task failure callbacks feed into the same two-channel routing
- [ ] A runbook exists for at least: Airbyte sync failure, dbt build failure, ClickHouse unreachable — each linked from its alert message
- [ ] Triggering a real failure (e.g. stopping ClickHouse) produces a Critical alert in Teams with a working runbook link

## Blocked by

- 01-infra-bootstrap.md
