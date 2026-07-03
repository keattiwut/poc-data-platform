{{
    config(
        materialized='table',
        engine="ReplacingMergeTree(updated_at)",
        order_by="(transaction_id)"
    )
}}

SELECT
    -- transaction_id is the ORDER BY key for the ReplacingMergeTree engine below;
    -- ClickHouse forbids Nullable columns in a sorting key. stg_partner_transactions
    -- is a view over Parquet with all columns inferred as Nullable, so we cast the
    -- primary key to non-nullable here. This also enforces the invariant that
    -- transaction_id must never be null (the cast throws if it ever is).
    CAST(transaction_id AS String) AS transaction_id,
    -- Partner side (populated in this slice)
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
    -- Bank side: intentionally NULL until Issue 03 adds the reconciliation join (ADR-0012)
    CAST(NULL AS Nullable(String)) AS bank_id,
    CAST(NULL AS Nullable(DateTime64(6, 'UTC'))) AS bank_authorized_at,
    CAST(NULL AS Nullable(DateTime64(6, 'UTC'))) AS bank_captured_at,
    CAST(NULL AS Nullable(DateTime64(6, 'UTC'))) AS bank_settled_at,
    -- ReplacingMergeTree's version column must not be Nullable either (same
    -- upstream-view-is-all-Nullable reason as transaction_id above).
    CAST(updated_at AS DateTime64(6, 'UTC')) AS updated_at
FROM {{ ref('stg_partner_transactions') }}
