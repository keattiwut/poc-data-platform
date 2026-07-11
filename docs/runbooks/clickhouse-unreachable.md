# Runbook: ClickHouse unreachable

**Alert**: `ClickHouseUnreachable` (Critical). Superset dashboards and any
dbt build are down until this is fixed.

## Diagnose

1. Is the container running? `docker compose ps clickhouse`
2. If it's up but not answering, check its logs:
   `docker compose logs clickhouse --tail 100` (or Grafana → Pipeline Infra
   Health → Service logs, `container="clickhouse"`).
3. Common causes seen in this stack:
   - Docker engine restarted and the container stayed exited → step 4.
   - Bad config under `clickhouse/config/` (it fails fast at startup with the
     offending file named in the log).
   - Out of disk on the Docker VM.

## Fix

4. `docker compose up -d clickhouse` and wait for the healthcheck:
   `docker compose ps clickhouse` shows `(healthy)` within ~1 minute.
5. Verify: `./scripts/verify-clickhouse.sh`.
6. If the daily 02:00 run failed while ClickHouse was down, re-run it:
   `docker compose exec airflow-scheduler airflow dags trigger daily_pipeline`
   then confirm all tasks green and dashboards populated
   (`./scripts/verify-superset-chart.sh`).

## Escalate

Data is safe: the warehouse is fully rebuilt from the lake by dbt, and
ClickHouse state lives on the `clickhouse-data` volume. Worst case:
`docker compose down clickhouse && docker compose up -d clickhouse` and
re-run `daily_pipeline`.
