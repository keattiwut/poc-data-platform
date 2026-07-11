{{ config(materialized='table', engine='MergeTree()', order_by='(partner_id)') }}

-- Conformed partner dimension (ADR-0007, Issue 06). Surrogate key is a
-- deterministic hash of the natural key: stable across rebuilds without any
-- sequence state, which matters because every dbt build fully recreates
-- this table. Attribute columns beyond the id arrive when a real partner
-- reference feed exists; the mock catalog only carries ids.
SELECT
    cityHash64(partner_id) AS partner_key,
    partner_id
FROM (
    -- assumeNotNull: the WHERE guarantees it, and MergeTree sorting keys
    -- reject Nullable columns.
    SELECT DISTINCT assumeNotNull(partner_id) AS partner_id
    FROM {{ ref('int_reconciled_transactions') }}
    WHERE partner_id IS NOT NULL
)
