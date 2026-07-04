{{
    config(
        materialized='table',
        engine="MergeTree()",
        order_by="(transaction_id)"
    )
}}

-- Bank/Partner reconciliation via FULL OUTER JOIN (ADR-0012, Issue 03).
--
-- This joins int_partner_transactions / int_bank_transactions - physical
-- MergeTree snapshots of the stg_partner_transactions / stg_bank_transactions
-- views - rather than the staging views themselves. That indirection exists
-- to work around a real ClickHouse 24.10.4 bug found while verifying this
-- task against the running instance: joining directly against the
-- `s3()`-backed staging views (even via a CTE, a parenthesized subquery, or
-- a UNION ALL instead of FULL JOIN - all were tried) silently returns NULL
-- for an unpredictable subset of the joined-in columns, including for rows
-- that plainly matched on both sides. `bank_id`, `decline_reason` and
-- `bank_decline_reason` were the columns most consistently affected in
-- testing, but which columns broke changed depending on total column count,
-- so this isn't a "just drop the outer LEFT JOIN of fee_schedule" fix - it
-- reproduces with nothing but this reconciliation join in isolation. See
-- int_partner_transactions.sql's header comment for the verified fix
-- (snapshot each staging view into a real table first, then join those).
--
-- Two smaller things also verified against the real instance:
-- 1. `stg_partner_transactions` has no `bank_id` column at all (only
--    `stg_bank_transactions` does), so bank_id can only come from `bank`,
--    not from a coalesce() across both sides.
-- 2. `FULL OUTER JOIN` is accepted verbatim by this ClickHouse version, no
--    rewrite to `FULL JOIN` needed.

WITH partner AS (
    SELECT * FROM {{ ref('int_partner_transactions') }}
),
bank AS (
    SELECT * FROM {{ ref('int_bank_transactions') }}
)
SELECT
    CAST(coalesce(partner.transaction_id, bank.transaction_id) AS String) AS transaction_id,
    coalesce(partner.partner_id, bank.partner_id) AS partner_id,
    coalesce(partner.amount_cents, bank.amount_cents) AS amount_cents,
    coalesce(partner.currency, bank.currency) AS currency,
    partner.state,
    partner.decline_reason,
    partner.initiated_at,
    partner.authorized_at,
    partner.captured_at,
    partner.settled_at,
    partner.failed_at,
    partner.refunded_at,
    bank.bank_id AS bank_id,
    bank.state AS bank_state,
    bank.decline_reason AS bank_decline_reason,
    bank.authorized_at AS bank_authorized_at,
    bank.captured_at AS bank_captured_at,
    bank.settled_at AS bank_settled_at,
    bank.failed_at AS bank_failed_at,
    CAST(greatest(
        coalesce(partner.updated_at, toDateTime64('1970-01-01 00:00:00', 6, 'UTC')),
        coalesce(bank.updated_at, toDateTime64('1970-01-01 00:00:00', 6, 'UTC'))
    ) AS DateTime64(6, 'UTC')) AS updated_at
FROM partner
FULL OUTER JOIN bank ON partner.transaction_id = bank.transaction_id
