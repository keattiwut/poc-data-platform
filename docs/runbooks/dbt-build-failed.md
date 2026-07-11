# Runbook: dbt build failed

**Alert**: Critical (Airflow `daily_pipeline.dbt_build` failure callback).
Also covers `dbt_source_freshness` failures - a freshness *error* means
silver has had no new data for 8+ hours and the morning SLA is blown.

## Diagnose

1. Read the task log first:
   Airflow UI → daily_pipeline → latest run → `dbt_build` (or
   `dbt_source_freshness`) → log. dbt names the failing model/test and
   prints the compiled SQL path.
2. Which kind of failure?
   - **Test failure** (e.g. `unique_stg_partner_transactions_transaction_id`):
     bad data got past its defense. For duplicates, the bronze→silver dedup
     should have absorbed them - check
     `scripts/promote-bronze-to-silver.py` ran (the promote tasks upstream)
     and that nobody left `PROMOTE_SKIP_DEDUP=1` set.
   - **Model/connection error** (`Code: 210`, connection refused): ClickHouse
     is down → [clickhouse-unreachable.md](./clickhouse-unreachable.md).
   - **Freshness error**: upstream extraction produced nothing → check the
     extract tasks in the same run; see
     [extraction-task-failed.md](./extraction-task-failed.md).

## Fix

3. Reproduce interactively:
   `docker compose exec airflow-scheduler bash -c "cd /opt/airflow/dbt/payment_gateway && DBT_PROFILES_DIR=. dbt build"`
4. For test failures, inspect the offending rows: dbt prints the compiled
   test SQL under `target/compiled/...`; run it via
   `docker compose exec clickhouse clickhouse-client`.
5. After the cause is fixed, clear/re-run the task from the Airflow UI or
   re-trigger the whole DAG - the pipeline is a full rebuild, so a re-run is
   always safe.

## If it's the mock data itself

The generator deliberately injects anomalies (Issue 05). Handled anomalies
never fail tests; if one does, the *defense* regressed - fix the promotion
dedup / reconciliation logic, don't relax the test.
