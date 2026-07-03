#!/usr/bin/env python3
"""Promotes bronze-zone partner_transactions Parquet to silver: dedups by
transaction_id, keeping the row with the latest updated_at."""
import os

import duckdb

MINIO_ENDPOINT = "localhost:9000"


def main() -> None:
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(f"""
        SET s3_endpoint='{MINIO_ENDPOINT}';
        SET s3_access_key_id='{os.environ["MINIO_ROOT_USER"]}';
        SET s3_secret_access_key='{os.environ["MINIO_ROOT_PASSWORD"]}';
        SET s3_use_ssl=false;
        SET s3_url_style='path';
    """)

    con.execute("""
        COPY (
            SELECT * EXCLUDE (rn) FROM (
                SELECT *,
                       ROW_NUMBER() OVER (
                           PARTITION BY transaction_id
                           ORDER BY updated_at DESC
                       ) AS rn
                FROM read_parquet('s3://data-lake/bronze/partner_transactions/**/*.parquet')
            )
            WHERE rn = 1
        ) TO 's3://data-lake/silver/partner_transactions/data.parquet' (FORMAT PARQUET);
    """)
    print("Promoted bronze/partner_transactions -> silver/partner_transactions")


if __name__ == "__main__":
    main()
