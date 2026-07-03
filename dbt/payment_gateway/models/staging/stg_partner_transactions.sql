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
FROM s3(
    'http://minio:9000/data-lake/silver/partner_transactions/*.parquet',
    '{{ env_var("MINIO_ROOT_USER") }}',
    '{{ env_var("MINIO_ROOT_PASSWORD") }}',
    'Parquet'
)
