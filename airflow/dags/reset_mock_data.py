"""Reset mock data DAG (Issue 05 / ADR-0010): wipes every system that holds
mock data - the mock Postgres tables, the SFTP upload directory, the Kafka
topics (plus dlt's consumed-offset state, which must go with them), the lake
bronze/silver zones, and the ClickHouse warehouse - then reseeds a fresh
backfill and re-runs the real pipeline over it.

Manual-trigger only (schedule=None): the generator is append-only by default
and a reset must never happen implicitly. For demo resets or a clean
dev-iteration slate.
"""

from airflow.providers.standard.operators.bash import BashOperator
from airflow.providers.standard.operators.trigger_dagrun import (
    TriggerDagRunOperator,
)
from airflow.sdk import dag


@dag(
    dag_id="reset_mock_data",
    schedule=None,
    catchup=False,
    max_active_runs=1,
    tags=["payment-gateway", "mock"],
)
def reset_mock_data():
    wipe = BashOperator(
        task_id="wipe_all_systems",
        bash_command="python /opt/airflow/scripts/reset-mock-data.py",
    )

    reseed = BashOperator(
        task_id="reseed_backfill",
        bash_command="python /opt/airflow/mock/generate_transactions.py --backfill",
    )

    # Refill the lake and warehouse from the fresh backfill immediately,
    # instead of leaving dashboards empty until daily_pipeline's next
    # scheduled run.
    rerun_pipeline = TriggerDagRunOperator(
        task_id="run_daily_pipeline",
        trigger_dag_id="daily_pipeline",
    )

    wipe >> reseed >> rerun_pipeline


reset_mock_data()
