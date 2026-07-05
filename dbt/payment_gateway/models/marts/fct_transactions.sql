{{
    config(
        materialized='table',
        engine="ReplacingMergeTree(updated_at)",
        order_by="(transaction_id)"
    )
}}

-- Fee-at-capture computation on top of the Bank/Partner reconciliation
-- (ADR-0012, Issue 03). The actual FULL OUTER JOIN lives in
-- int_reconciled_transactions.sql, not here - see that model's header
-- comment for why: combining the FULL OUTER JOIN and this fee LEFT JOIN in
-- a single INSERT-with-explicit-column-list statement (which is what
-- dbt-clickhouse's `table` materialization always issues) hit a real
-- ClickHouse 24.10.4 bug that silently NULLed out an unpredictable subset of
-- columns. Reading the already-materialized int_reconciled_transactions
-- table here avoids it entirely (verified against the running instance).
--
-- Also verified against the running instance: `fee_schedule` (a dbt seed)
-- loads its numeric columns as non-Nullable Int32 (see `DESCRIBE TABLE
-- fee_schedule`). ClickHouse's default `join_use_nulls = 0` setting means an
-- unmatched LEFT JOIN against a non-Nullable column fills with that type's
-- *default value* (0 for Int32) rather than NULL - unlike this model's own
-- Nullable(String)/Nullable(DateTime64) columns, which already come back as
-- NULL when unmatched regardless of this setting. Left as-is, a Partner-only
-- captured row with no matching Bank/fee combination would get a wrong
-- `fee_amount_cents` of 0 instead of NULL. `SETTINGS join_use_nulls = 1` on
-- this query forces unmatched fee_schedule columns to come back
-- Nullable/NULL as expected, so the CASE below yields real NULL when
-- there's no fee-schedule match.

SELECT
    reconciled.transaction_id,
    reconciled.partner_id,
    reconciled.amount_cents,
    reconciled.currency,
    reconciled.state,
    reconciled.decline_reason,
    reconciled.initiated_at,
    reconciled.authorized_at,
    reconciled.captured_at,
    reconciled.settled_at,
    reconciled.failed_at,
    reconciled.refunded_at,
    reconciled.bank_id,
    reconciled.bank_state,
    reconciled.bank_decline_reason,
    reconciled.bank_authorized_at,
    reconciled.bank_captured_at,
    reconciled.bank_settled_at,
    reconciled.bank_failed_at,
    reconciled.updated_at,
    CASE
        WHEN reconciled.bank_captured_at IS NOT NULL OR reconciled.captured_at IS NOT NULL
        THEN fee.fixed_fee_cents + toInt64(round(reconciled.amount_cents * fee.percentage_bps / 10000.0))
        ELSE NULL
    END AS fee_amount_cents
FROM {{ ref('int_reconciled_transactions') }} AS reconciled
LEFT JOIN {{ ref('fee_schedule') }} AS fee
    ON reconciled.partner_id = fee.partner_id AND reconciled.bank_id = fee.bank_id
SETTINGS join_use_nulls = 1
