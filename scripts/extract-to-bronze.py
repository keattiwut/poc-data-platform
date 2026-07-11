#!/usr/bin/env python3
"""dlt extraction to the bronze zone (Issue 04 / ADR-0024, replacing Airbyte).

One channel per invocation, matching the four PRD source types:

    extract-to-bronze.py partner_db   # Postgres partner_transactions
    extract-to-bronze.py bank_db     # Postgres bank_transactions
    extract-to-bronze.py sftp        # CSV files dropped on the mock SFTP server
    extract-to-bronze.py kafka       # partner-/bank-transactions topics, drained
                                     # as a batch (ADR-0001), offsets tracked in
                                     # dlt state so each run reads only new messages

Each channel is its own dlt pipeline/dataset, so bronze paths are
s3://data-lake/bronze/<channel_dataset>/<table>/*.parquet and one channel's
write disposition can never touch another channel's files. The promotion
script reads bronze/*/<table>/**/*.parquet, so all channels feeding the same
logical table (partner_transactions / bank_transactions) converge in silver.

Postgres and SFTP are full-refresh (`replace`) like the Airbyte connections
they replace; Kafka is `append` because the offset tracker already makes each
drain incremental. Duplicate rows across loads are collapsed by the silver
promotion's dedup (latest updated_at per transaction_id).

Env (Vault->.env render, ADR-0006; in-network values on the Airflow
scheduler): POSTGRES_HOST/PORT/USER/PASSWORD, MINIO_ENDPOINT +
MINIO_ROOT_USER/PASSWORD, SFTP_HOST/PORT/USER/PASSWORD,
KAFKA_BOOTSTRAP_SERVERS. Host-side runs override the hosts/ports as usual
(e.g. POSTGRES_HOST=localhost SFTP_HOST=localhost SFTP_PORT=12222
KAFKA_BOOTSTRAP_SERVERS=localhost:9094).
"""
import csv
import io
import json
import os
import sys
from datetime import datetime
from urllib.parse import quote_plus

import dlt

# The CSV/JSON transport channels carry ISO8601 strings and empty/null blanks
# (see mock/generate_transactions.py serialize_for_transport); parse them back
# so every channel lands in bronze with the same column types as the Postgres
# channel (real timestamps, bigint amount).
TIMESTAMP_FIELDS = {
    "initiated_at", "authorized_at", "captured_at",
    "settled_at", "failed_at", "refunded_at", "updated_at",
}


def canonical_row(row: dict) -> dict:
    out = {}
    for key, value in row.items():
        if value is None or value == "":
            out[key] = None
        elif key in TIMESTAMP_FIELDS:
            out[key] = datetime.fromisoformat(value)
        elif key == "amount_cents":
            out[key] = int(value)
        else:
            out[key] = value
    return out


def bronze_pipeline(channel: str, dataset: str) -> dlt.Pipeline:
    minio_endpoint = os.environ.get("MINIO_ENDPOINT", "localhost:9000")
    return dlt.pipeline(
        pipeline_name=f"bronze_{channel}",
        destination=dlt.destinations.filesystem(
            bucket_url="s3://data-lake/bronze",
            credentials={
                "aws_access_key_id": os.environ["MINIO_ROOT_USER"],
                "aws_secret_access_key": os.environ["MINIO_ROOT_PASSWORD"],
                "endpoint_url": f"http://{minio_endpoint}",
            },
            layout="{table_name}/{load_id}.{file_id}.{ext}",
        ),
        dataset_name=dataset,
    )


def extract_postgres(channel: str, table: str) -> None:
    from dlt.sources.sql_database import sql_table

    creds = (
        f"postgresql://{quote_plus(os.environ['POSTGRES_USER'])}:"
        f"{quote_plus(os.environ['POSTGRES_PASSWORD'])}"
        f"@{os.environ.get('POSTGRES_HOST', 'localhost')}:"
        f"{os.environ.get('POSTGRES_PORT', '5432')}"
        f"/{os.environ.get('POSTGRES_DB', 'pipeline')}"
    )
    # backend="pyarrow" streams Arrow straight to Parquet (verified in
    # scripts/spike-dlt-partner-extraction.py, the ADR-0024 prototype).
    resource = sql_table(credentials=creds, table=table, backend="pyarrow")
    info = bronze_pipeline(channel, channel).run(
        resource, loader_file_format="parquet", write_disposition="replace"
    )
    print(info)


def extract_sftp() -> None:
    from dlt.sources.filesystem import filesystem

    # dlt's filesystem source reads SFTP credentials from config, not from a
    # credentials= kwarg dict; provide them via in-process env vars.
    os.environ["SOURCES__FILESYSTEM__CREDENTIALS__SFTP_USERNAME"] = os.environ["SFTP_USER"]
    os.environ["SOURCES__FILESYSTEM__CREDENTIALS__SFTP_PASSWORD"] = os.environ["SFTP_PASSWORD"]
    os.environ["SOURCES__FILESYSTEM__CREDENTIALS__SFTP_PORT"] = os.environ.get("SFTP_PORT", "22")
    bucket_url = f"sftp://{os.environ['SFTP_HOST']}/upload"

    @dlt.transformer()
    def read_transactions_csv(file_items):
        for file_item in file_items:
            with file_item.open() as f:
                for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8")):
                    yield canonical_row(row)

    resources = [
        (filesystem(bucket_url=bucket_url, file_glob=f"{table}_*.csv") | read_transactions_csv)
        .with_name(table)
        for table in ("partner_transactions", "bank_transactions")
    ]
    # Full refresh: every run re-reads all CSVs still on the server, like the
    # Postgres channels re-read their whole table.
    info = bronze_pipeline("sftp", "sftp_drop").run(
        resources, loader_file_format="parquet", write_disposition="replace"
    )
    print(info)


def extract_kafka() -> None:
    # Vendored dlt verified source (see scripts/kafka_source/README.md);
    # importable because this script's own directory is on sys.path.
    from kafka_source import kafka_consumer
    from kafka_source.helpers import KafkaCredentials

    creds = KafkaCredentials(
        bootstrap_servers=os.environ["KAFKA_BOOTSTRAP_SERVERS"],
        group_id="daily_pipeline_drain",
        security_protocol="PLAINTEXT",
    )

    def transaction_msg_processor(msg) -> dict:
        return canonical_row(json.loads(msg.value()))

    resources = []
    for topic, table in (
        ("partner-transactions", "partner_transactions"),
        ("bank-transactions", "bank_transactions"),
    ):
        resource = kafka_consumer(
            topics=topic, credentials=creds, msg_processor=transaction_msg_processor
        ).with_name(f"drain_{table}")
        # Override the source's per-topic table routing with the canonical
        # bronze table name.
        resource.apply_hints(table_name=table)
        resources.append(resource)

    # Append: the OffsetTracker persists consumed offsets in dlt state (synced
    # to the destination), so each daily run drains only new messages. If
    # state is ever lost the drain restarts from earliest and the silver dedup
    # absorbs the duplicates.
    info = bronze_pipeline("kafka", "kafka_drain").run(
        resources, loader_file_format="parquet", write_disposition="append"
    )
    print(info)


CHANNELS = {
    "partner_db": lambda: extract_postgres("partner_db", "partner_transactions"),
    "bank_db": lambda: extract_postgres("bank_db", "bank_transactions"),
    "sftp": extract_sftp,
    "kafka": extract_kafka,
}


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in CHANNELS:
        print(f"Usage: extract-to-bronze.py <{'|'.join(CHANNELS)}>", file=sys.stderr)
        sys.exit(1)
    CHANNELS[sys.argv[1]]()


if __name__ == "__main__":
    main()
