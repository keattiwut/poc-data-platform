{{ config(materialized='view') }}

SELECT
    transaction_id,
    partner_id,
    amount_cents,
    currency,
    state,
    decline_reason,
    initiated_at,
    authorized_at,
    captured_at,
    settled_at,
    failed_at,
    refunded_at,
    updated_at
-- Credentials come from the `minio_s3` named collection (server-side config,
-- see clickhouse/config/named_collections.xml), not inline in this query.
-- ClickHouse masks named-collection secrets in system.named_collections and
-- the query log, so they never land in this view's stored DDL or dbt's
-- compiled-SQL build artifacts the way a literal env_var()-injected value
-- would.
FROM s3(
    minio_s3,
    url = 'http://minio:9000/data-lake/silver/partner_transactions/*.parquet',
    format = 'Parquet'
)
