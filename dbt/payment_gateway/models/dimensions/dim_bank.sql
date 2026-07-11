{{ config(materialized='table', engine='MergeTree()', order_by='(bank_id)') }}

-- Conformed bank dimension (ADR-0007, Issue 06). See dim_partner.sql for
-- why the surrogate key is a deterministic hash.
SELECT
    cityHash64(bank_id) AS bank_key,
    bank_id
FROM (
    -- assumeNotNull: the WHERE guarantees it, and MergeTree sorting keys
    -- reject Nullable columns.
    SELECT DISTINCT assumeNotNull(bank_id) AS bank_id
    FROM {{ ref('int_reconciled_transactions') }}
    WHERE bank_id IS NOT NULL
)
