"""Daily pipeline DAG (Issue 11 / ADR-0021): the first real DAG, replacing the
manual shell-script run that verify-walking-skeleton.sh exercises.

    extract partner_db ──┐
    extract bank_db    ──┤   promote partner_transactions ─┐
    extract sftp       ──┼─> ├─> dbt build
    extract kafka      ──┘   promote bank_transactions   ──┘

Extraction (Issue 04 / ADR-0024) is dlt running in-process as ordinary tasks
(scripts/extract-to-bronze.py), one per source channel, replacing the Airbyte
platform. The SFTP and Kafka channels each carry rows for *both* logical
tables, so every promotion depends on every extraction.

Written against Airflow 3 APIs: `airflow.sdk` for the @dag decorator and the
standard provider's BashOperator (both bundled in apache/airflow:3.3.0).

Runtime wiring (POC route, all set up in docker-compose.yml on the
airflow-scheduler service, where LocalExecutor tasks actually run):
  - ./scripts is mounted at /opt/airflow/scripts (promotion script) and ./dbt
    at /opt/airflow/dbt (dbt project).
  - The Airflow image ships neither duckdb nor dbt; _PIP_ADDITIONAL_REQUIREMENTS
    ("duckdb dbt-core dbt-clickhouse") pip-installs them at container start.
    That is a dev-only convenience - the non-POC fix is a custom image.
  - Task env comes from the container: MINIO_ENDPOINT=minio:9000 plus
    MINIO_ROOT_USER/PASSWORD for promotion; CLICKHOUSE_USER/PASSWORD for dbt.

dbt connectivity: profiles.yml reads CLICKHOUSE_HOST/CLICKHOUSE_PORT env vars
(defaulting to the host-side localhost:8124 mapping); the scheduler service
sets them to the in-network clickhouse:8123 so this DAG's dbt task connects.
"""

from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import dag

EXTRACT = "python /opt/airflow/scripts/extract-to-bronze.py"
PROMOTE = "python /opt/airflow/scripts/promote-bronze-to-silver.py"
DBT_DIR = "/opt/airflow/dbt/payment_gateway"


@dag(
    dag_id="daily_pipeline",
    # 02:00, two hours after mock_data_producer (00:00), so each day's mock
    # batch exists before extraction runs (Issue 05 / ADR-0010).
    schedule="0 2 * * *",
    catchup=False,
    # Two overlapping runs race in dbt ("Table already exists", observed on
    # first bring-up when unpausing created a scheduled run next to a manual
    # trigger). The pipeline is a full rebuild; overlap is never useful.
    max_active_runs=1,
    tags=["payment-gateway"],
)
def daily_pipeline():
    # One dlt extraction task per source channel (ADR-0024). Kafka is drained
    # as a batch here on the daily schedule, not consumed continuously
    # (ADR-0001).
    extracts = [
        BashOperator(task_id=f"extract_{channel}", bash_command=f"{EXTRACT} {channel}")
        for channel in ("partner_db", "bank_db", "sftp", "kafka")
    ]

    promote_partner = BashOperator(
        task_id="promote_partner_transactions",
        bash_command=f"{PROMOTE} partner_transactions",
    )

    promote_bank = BashOperator(
        task_id="promote_bank_transactions",
        bash_command=f"{PROMOTE} bank_transactions",
    )

    dbt_build = BashOperator(
        task_id="dbt_build",
        # dbt build = seed + run + test in dependency order; DBT_PROFILES_DIR
        # points at the project-local profiles.yml (same as the verify
        # scripts), which reads CLICKHOUSE_HOST/PORT from this container's env.
        bash_command=f"cd {DBT_DIR} && DBT_PROFILES_DIR=. dbt build",
    )

    # Freshness SLA check (Issue 07): breaches when silver's newest row is
    # stale enough that the 6-8 AM window is at risk (thresholds documented
    # in models/sources.yml). Runs beside dbt_build, not in front of it - a
    # freshness alarm should not stop the data that DID arrive from flowing.
    source_freshness = BashOperator(
        task_id="dbt_source_freshness",
        bash_command=f"cd {DBT_DIR} && DBT_PROFILES_DIR=. dbt source freshness",
    )

    # SFTP/Kafka extractions feed both tables, so both promotions wait for
    # all four channels; promotions are independent tables -> run in
    # parallel, then transform.
    extracts >> promote_partner
    extracts >> promote_bank
    [promote_partner, promote_bank] >> dbt_build
    [promote_partner, promote_bank] >> source_freshness


daily_pipeline()
