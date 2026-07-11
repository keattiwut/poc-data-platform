#!/usr/bin/env python3
"""Wipes every system holding mock data (Issue 05 / ADR-0010), for the
reset_mock_data DAG. Runs inside the airflow-scheduler container (all deps
come from _PIP_ADDITIONAL_REQUIREMENTS; all endpoints/credentials from the
Vault->.env render on the container env).

Five systems plus one piece of derived state:
  1. mock Postgres: TRUNCATE partner_transactions / bank_transactions
  2. SFTP: delete every file in upload/
  3. Kafka: delete both transaction topics (recreated on next produce -
     the broker runs with KAFKA_AUTO_CREATE_TOPICS_ENABLE)
  4. dlt state: local pipeline dirs + whatever the lake wipe removes.
     Deleting topics resets broker offsets to 0 while dlt's OffsetTracker
     remembers the old (higher) consumed offsets - without this step the
     next drain would silently skip all new messages forever.
  5. lake: bronze/ and silver/ zones on MinIO
  6. warehouse: every table/view in the ClickHouse database dbt builds into
     (recreated by the next dbt build)

Wiping only; reseeding is the DAG's next task (the generator's --backfill).
"""
import os
import shutil
from pathlib import Path

import clickhouse_connect
import paramiko
import psycopg2
import s3fs
from confluent_kafka.admin import AdminClient

TOPICS = ["partner-transactions", "bank-transactions"]


def wipe_postgres() -> None:
    conn = psycopg2.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        dbname="pipeline",
    )
    try:
        with conn.cursor() as cur:
            # IF EXISTS via to_regclass: a fresh stack may not have the
            # tables yet, and TRUNCATE on a missing table would fail the DAG.
            for table in ("partner_transactions", "bank_transactions"):
                cur.execute("SELECT to_regclass(%s)", (table,))
                if cur.fetchone()[0]:
                    cur.execute(f"TRUNCATE {table}")
                    print(f"Postgres: truncated {table}")
        conn.commit()
    finally:
        conn.close()


def wipe_sftp() -> None:
    transport = paramiko.Transport(
        (os.environ["SFTP_HOST"], int(os.environ.get("SFTP_PORT", "22")))
    )
    transport.connect(
        username=os.environ["SFTP_USER"], password=os.environ["SFTP_PASSWORD"]
    )
    sftp = paramiko.SFTPClient.from_transport(transport)
    try:
        files = sftp.listdir("upload")
        for name in files:
            sftp.remove(f"upload/{name}")
        print(f"SFTP: removed {len(files)} file(s) from upload/")
    finally:
        sftp.close()
        transport.close()


def wipe_kafka() -> None:
    admin = AdminClient(
        {"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP_SERVERS"]}
    )
    existing = set(admin.list_topics(timeout=15).topics)
    to_delete = [t for t in TOPICS if t in existing]
    if not to_delete:
        print("Kafka: no transaction topics to delete")
        return
    for topic, future in admin.delete_topics(to_delete, operation_timeout=30).items():
        future.result()
        print(f"Kafka: deleted topic {topic}")


def wipe_dlt_state() -> None:
    # Local working-dir state takes precedence over the destination copy, so
    # both must go (the destination copy disappears with the lake wipe).
    pipelines_dir = Path.home() / ".dlt" / "pipelines"
    shutil.rmtree(pipelines_dir, ignore_errors=True)
    print(f"dlt: removed local pipeline state at {pipelines_dir}")


def wipe_lake() -> None:
    fs = s3fs.S3FileSystem(
        key=os.environ["MINIO_ROOT_USER"],
        secret=os.environ["MINIO_ROOT_PASSWORD"],
        client_kwargs={
            "endpoint_url": f"http://{os.environ.get('MINIO_ENDPOINT', 'localhost:9000')}"
        },
    )
    for zone in ("data-lake/bronze", "data-lake/silver"):
        # One DELETE per object, not fs.rm(recursive=True): the bulk
        # DeleteObjects call fails against MinIO with MissingContentMD5
        # (botocore stopped sending the Content-MD5 header MinIO requires).
        objects = fs.find(zone)
        for path in objects:
            fs.rm_file(path)
        print(f"Lake: wiped {zone} ({len(objects)} object(s))")


def wipe_warehouse() -> None:
    client = clickhouse_connect.get_client(
        host=os.environ.get("CLICKHOUSE_HOST", "localhost"),
        port=int(os.environ.get("CLICKHOUSE_PORT", "8123")),
        username=os.environ["CLICKHOUSE_USER"],
        password=os.environ["CLICKHOUSE_PASSWORD"],
    )
    # The dbt target database holds only dbt-built relations (plus the seed);
    # drop them all rather than maintaining a name list here.
    relations = client.query(
        "SELECT name, engine FROM system.tables WHERE database = currentDatabase()"
    ).result_rows
    for name, engine in relations:
        kind = "VIEW" if engine == "View" else "TABLE"
        client.command(f"DROP {kind} IF EXISTS `{name}`")
        print(f"Warehouse: dropped {kind.lower()} {name}")
    if not relations:
        print("Warehouse: already empty")


def main() -> None:
    wipe_postgres()
    wipe_sftp()
    wipe_kafka()
    wipe_dlt_state()
    wipe_lake()
    wipe_warehouse()
    print("Reset complete: all mock-data systems wiped.")


if __name__ == "__main__":
    main()
