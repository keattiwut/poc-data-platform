{{ config(materialized='view') }}

SELECT
    transaction_id,
    partner_id,
    bank_id,
    amount_cents,
    currency,
    state,
    decline_reason,
    authorized_at,
    captured_at,
    settled_at,
    failed_at,
    refunded_at,
    updated_at
-- Credentials come from the `minio_s3` named collection (server-side config,
-- clickhouse/config/named_collections.xml), not inline in this query - see
-- stg_partner_transactions.sql / the credential-exposure fix on master for
-- why (ClickHouse masks named-collection secrets; a literal env_var()
-- credential would land in this view's stored DDL and the query log).
FROM s3(
    minio_s3,
    url = 'https://minio:9000/data-lake/silver/bank_transactions/*.parquet',
    format = 'Parquet'
)
