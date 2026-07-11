{{ config(materialized='table', engine='MergeTree()', order_by='(decline_reason)') }}

-- Conformed decline-reason dimension (ADR-0007, Issue 06), unioned across
-- both reporting sides: either side can decline, and the dashboard's
-- breakdown treats "the" decline reason as partner-side first, bank-side
-- otherwise (see mart_transactions.effective_decline_reason).
SELECT
    cityHash64(decline_reason) AS decline_reason_key,
    decline_reason
FROM (
    -- assumeNotNull: the WHEREs guarantee it, and MergeTree sorting keys
    -- reject Nullable columns.
    SELECT DISTINCT assumeNotNull(decline_reason) AS decline_reason
    FROM {{ ref('int_reconciled_transactions') }}
    WHERE decline_reason IS NOT NULL

    UNION DISTINCT

    SELECT DISTINCT assumeNotNull(bank_decline_reason) AS decline_reason
    FROM {{ ref('int_reconciled_transactions') }}
    WHERE bank_decline_reason IS NOT NULL
)
