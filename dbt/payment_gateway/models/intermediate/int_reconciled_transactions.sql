{{
    config(
        materialized='table',
        engine="MergeTree()",
        order_by="(transaction_id)"
    )
}}

-- Bank/Partner reconciliation via FULL OUTER JOIN (ADR-0012, Issue 03),
-- joining the s3()-backed staging views directly.
--
-- History (ADR-0022): on ClickHouse 24.10.4 this join silently NULLed an
-- unpredictable subset of joined-in columns when a side was an s3()-backed
-- view, so each staging view was first snapshotted into a physical
-- int_partner_transactions / int_bank_transactions table and the join ran
-- on those. Verified fixed on 26.3 (2026-07-10) by
-- scripts/verify-clickhouse-s3-join-bug.sh, so the snapshot models were
-- deleted. If that repro script ever fails after a ClickHouse upgrade,
-- restore the snapshot indirection (see git history / ADR-0022).
--
-- bank_id: both sides know it (the mock gateway already knows which bank a
-- transaction is routed to, so it writes bank_id on partner_transactions
-- too, not just bank_transactions - see stg_partner_transactions.sql). Use
-- coalesce(partner.bank_id, bank.bank_id) so a Partner-only orphan (Bank
-- hasn't reported yet) still carries its bank_id through to the fee-schedule
-- lookup in fct_transactions.sql, instead of going NULL and silently
-- dropping its fee.

WITH partner AS (
    SELECT * FROM {{ ref('stg_partner_transactions') }}
),
bank AS (
    SELECT * FROM {{ ref('stg_bank_transactions') }}
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
    coalesce(partner.bank_id, bank.bank_id) AS bank_id,
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
