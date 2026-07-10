#!/usr/bin/env python3
"""Promotes bronze-zone Parquet to silver: dedups by transaction_id, keeping
the row with the latest updated_at. Generalized (Issue 03) from Issue 02's
partner-transactions-only version - takes the table name as an argument so
the same logic covers both partner_transactions and bank_transactions.

Issue 04 (ADR-0024): bronze is now written by per-channel dlt pipelines at
bronze/<channel_dataset>/<table>/*.parquet (four channels: partner_db,
bank_db, sftp_drop, kafka_drain), so the glob matches one directory level of
channel datasets. Channels differ slightly in metadata columns (dlt adds
_dlt_id/_dlt_load_id on the non-arrow paths), so files are unioned by name
and only the canonical business columns are promoted - this column list IS
the bronze->silver contract."""
import os
import sys

import duckdb

COLUMNS = {
    "partner_transactions": (
        "transaction_id", "partner_id", "bank_id", "amount_cents", "currency",
        "state", "decline_reason", "initiated_at", "authorized_at",
        "captured_at", "settled_at", "failed_at", "refunded_at", "updated_at",
    ),
    "bank_transactions": (
        "transaction_id", "partner_id", "bank_id", "amount_cents", "currency",
        "state", "decline_reason", "authorized_at", "captured_at",
        "settled_at", "failed_at", "refunded_at", "updated_at",
    ),
}

# Overridable so the same script works host-side (localhost:9000) and inside
# a container on the compose network (minio:9000).
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "localhost:9000")


def promote(table: str) -> None:
    columns = ", ".join(COLUMNS[table])
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(f"""
        SET s3_endpoint='{MINIO_ENDPOINT}';
        SET s3_access_key_id='{os.environ["MINIO_ROOT_USER"]}';
        SET s3_secret_access_key='{os.environ["MINIO_ROOT_PASSWORD"]}';
        SET s3_use_ssl=false;
        SET s3_url_style='path';
    """)

    con.execute(f"""
        COPY (
            SELECT {columns} FROM (
                SELECT *,
                       ROW_NUMBER() OVER (
                           PARTITION BY transaction_id
                           ORDER BY updated_at DESC
                       ) AS rn
                FROM read_parquet(
                    's3://data-lake/bronze/*/{table}/**/*.parquet',
                    union_by_name=true
                )
            )
            WHERE rn = 1
        ) TO 's3://data-lake/silver/{table}/data.parquet' (FORMAT PARQUET);
    """)
    print(f"Promoted bronze/*/{table} -> silver/{table}")


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in COLUMNS:
        print(f"Usage: promote-bronze-to-silver.py <{'|'.join(COLUMNS)}>", file=sys.stderr)
        sys.exit(1)
    promote(sys.argv[1])


if __name__ == "__main__":
    main()
