Status: ready-for-agent

# Adopt Airflow 3 and wire the first pipeline DAG

## Parent

`review_recommendation.md` (finding 1, finding 6) · `docs/adr/0021-airflow-3-before-first-dag.md`

## What to build

Airflow is deployed but orchestrates nothing — `airflow/dags/` contains only `.gitkeep` and the pipeline steps (bronze→silver promotion, dbt build) run by hand via shell scripts, which is the crontab pattern this project exists to replace. Since zero DAGs exist, this is the free moment to adopt Airflow 3 instead of writing DAGs against the winding-down 2.x line (ADR-0021).

Bump the three `apache/airflow` images in `docker-compose.yml` to a current Airflow 3 release (same LocalExecutor/Postgres-metadata topology; apply the small 3.x config/CLI renames, e.g. `airflow db migrate` and `standalone`/`api-server` changes as applicable). Then write the first real DAG: a daily pipeline that runs bronze→silver promotion for `partner_transactions` and `bank_transactions`, then `dbt build` — the steps `verify-full-stack.sh` currently exercises manually.

As part of making promotion orchestrable, fix `scripts/promote-bronze-to-silver.py`: the MinIO endpoint is hardcoded to `localhost:9000`, which breaks inside a container — read it from an env var (default `localhost:9000` for host runs).

## Acceptance criteria

- [ ] `docker-compose.yml` runs Airflow 3.x images; `verify-airflow.sh` passes against it (or is updated for 3.x health/CLI changes)
- [ ] A DAG exists that orders: promote partner_transactions → promote bank_transactions → dbt build (promotions may run in parallel)
- [ ] `promote-bronze-to-silver.py` reads the MinIO endpoint from an env var, not a hardcoded constant
- [ ] DAG parses cleanly (`airflow dags list` / import test) — written against Airflow 3 APIs, no 2.x-removed imports
- [ ] If a required provider (e.g. Cosmos for dbt, when adopted) doesn't support Airflow 3, that finding is documented in ADR-0021 and the fallback (stay on 2.10.x) is taken deliberately

## Blocked by

- 03-bank-side-reconciliation-and-fee-revenue.md
