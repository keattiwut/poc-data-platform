"""Mock data producer DAG (Issue 05 / ADR-0010): generates one simulated day
of correlated Partner/Bank transactions across all three transport channels
(Postgres, SFTP CSV, Kafka), append-only.

Scheduled at 00:00, two hours ahead of daily_pipeline (02:00), so each day's
mock batch exists before the real extraction runs - the "scheduled ahead of
the real extraction DAG" contract from ADR-0010. On the very first run
(empty mock DB) it backfills MOCK_BACKFILL_DAYS of history so the dashboard
has trend lines immediately.

Runs mock/generate_transactions.py inside this scheduler container (./mock is
mounted at /opt/airflow/mock; paramiko/kafka-python come from
_PIP_ADDITIONAL_REQUIREMENTS - see docker-compose.yml). Pause this DAG to
stop mock data once real Bank/Partner access exists.
"""

from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import dag

GENERATE = "python /opt/airflow/mock/generate_transactions.py"


@dag(
    dag_id="mock_data_producer",
    schedule="0 0 * * *",
    catchup=False,
    max_active_runs=1,
    tags=["payment-gateway", "mock"],
)
def mock_data_producer():
    BashOperator(
        task_id="generate_daily_batch",
        # The run's logical date is the simulated day. Airflow 3 manual runs
        # have no logical date at all ('ds' renders undefined), so fall back
        # to the wall-clock date for those. The first-ever run backfills
        # history instead (see generator docstring).
        bash_command=(
            f"{GENERATE} --backfill-if-empty --day "
            "{{ ds | default(macros.datetime.now().strftime('%Y-%m-%d'), true) }}"
        ),
    )


mock_data_producer()
