#!/usr/bin/env python3
"""Issue 14 spike: dlt extraction of partner_transactions -> Parquet on MinIO.

UNVERIFIED SPIKE ARTIFACT: written against dlt docs current as of 2026-07-09
(dlthub.com/docs/dlt-ecosystem/verified-sources/sql_database and
dlthub.com/docs/dlt-ecosystem/destinations/filesystem) but NEVER EXECUTED —
Docker was down when authored. Evidence for ADR-0024 only; not in any DAG.

Deps (spike only): pip install "dlt[sql_database,filesystem]" pyarrow psycopg2-binary
Env (same Vault->.env render as everything else, ADR-0006):
POSTGRES_USER/POSTGRES_PASSWORD, MINIO_ROOT_USER/MINIO_ROOT_PASSWORD,
MINIO_ENDPOINT (host:port, default localhost:9000).

Output: s3://data-lake/bronze-dlt/partner_db/partner_transactions/*.parquet —
under bronze-dlt/ so it never collides with Airbyte's real bronze/ output.
"""
import os
from urllib.parse import quote_plus

import dlt
from dlt.sources.sql_database import sql_table


def main() -> None:
    pg_user = os.environ["POSTGRES_USER"]
    pg_password = os.environ["POSTGRES_PASSWORD"]
    pg_host = os.environ.get("POSTGRES_HOST", "localhost")
    pg_port = os.environ.get("POSTGRES_PORT", "5432")
    pg_db = os.environ.get("POSTGRES_DB", "pipeline")
    minio_endpoint = os.environ.get("MINIO_ENDPOINT", "localhost:9000")

    # MinIO is S3-compatible: standard AWS credential keys + endpoint_url.
    creds = {
        "aws_access_key_id": os.environ["MINIO_ROOT_USER"],
        "aws_secret_access_key": os.environ["MINIO_ROOT_PASSWORD"],
        "endpoint_url": f"http://{minio_endpoint}",
    }

    pipeline = dlt.pipeline(
        pipeline_name="spike_dlt_partner_extraction",
        destination=dlt.destinations.filesystem(
            bucket_url="s3://data-lake/bronze-dlt",
            credentials=creds,
            layout="{table_name}/{load_id}.{file_id}.{ext}",
        ),
        dataset_name="partner_db",
    )

    # backend="pyarrow" streams Arrow tables straight to Parquet (skips the
    # row-by-row normalizer; the docs cite a 20-30x speedup for this path).
    table = sql_table(
        credentials=f"postgresql://{quote_plus(pg_user)}:{quote_plus(pg_password)}"
        f"@{pg_host}:{pg_port}/{pg_db}",
        table="partner_transactions",
        backend="pyarrow",
    )

    # Full refresh, mirroring the Airbyte connection's full_refresh_overwrite.
    info = pipeline.run(table, loader_file_format="parquet", write_disposition="replace")
    print(info)


if __name__ == "__main__":
    main()
