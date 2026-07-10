"""Daily pipeline DAG (Issue 11 / ADR-0021): the first real DAG, replacing the
manual shell-script run that verify-walking-skeleton.sh exercises.

    promote partner_transactions ─┐
                                  ├─> dbt build
    promote bank_transactions   ──┘

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

PROMOTE = "python /opt/airflow/scripts/promote-bronze-to-silver.py"
DBT_DIR = "/opt/airflow/dbt/payment_gateway"


@dag(
    dag_id="daily_pipeline",
    schedule="@daily",
    catchup=False,
    # Two overlapping runs race in dbt ("Table already exists", observed on
    # first bring-up when unpausing created a scheduled run next to a manual
    # trigger). The pipeline is a full rebuild; overlap is never useful.
    max_active_runs=1,
    tags=["payment-gateway"],
)
def daily_pipeline():
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

    # Promotions are independent tables -> run in parallel, then transform.
    [promote_partner, promote_bank] >> dbt_build


daily_pipeline()
