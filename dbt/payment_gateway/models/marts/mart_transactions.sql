{{ config(materialized='view') }}

-- Dashboard-facing mart (ADR-0007, Issue 06): fct_transactions_current
-- joined to all four conformed dimensions, so every chart shares one
-- definition of bank/partner/date/decline-reason instead of re-deriving its
-- own. All Superset datasets point here.
--
-- join_use_nulls = 1: without it, ClickHouse fills unmatched LEFT JOIN
-- columns with type defaults (0 for the hash keys) instead of NULL - same
-- trap documented in fct_transactions.sql.

-- Explicit column list, not f.*: the dimension joins make partner_id /
-- bank_id / decline_reason ambiguous, and ClickHouse then names the view's
-- output columns literally "f.partner_id" etc., which breaks every consumer.
SELECT
    f.transaction_id,
    f.partner_id AS partner_id,
    f.amount_cents,
    f.currency,
    f.state,
    f.decline_reason AS decline_reason,
    f.initiated_at,
    f.authorized_at,
    f.captured_at,
    f.settled_at,
    f.failed_at,
    f.refunded_at,
    f.bank_id AS bank_id,
    f.bank_state,
    f.bank_decline_reason,
    f.bank_authorized_at,
    f.bank_captured_at,
    f.bank_settled_at,
    f.bank_failed_at,
    f.fee_amount_cents,
    f.updated_at,
    d.date_key,
    d.week_start,
    d.month_start,
    d.quarter,
    d.year,
    p.partner_key,
    b.bank_key,
    r.decline_reason_key,
    coalesce(f.decline_reason, f.bank_decline_reason) AS effective_decline_reason
FROM {{ ref('fct_transactions_current') }} AS f
-- Bank-only orphans have no initiated_at; fall back to updated_at so every
-- row lands on a calendar day.
LEFT JOIN {{ ref('dim_date') }} AS d
    ON toDate(coalesce(f.initiated_at, f.updated_at)) = d.date_day
LEFT JOIN {{ ref('dim_partner') }} AS p ON f.partner_id = p.partner_id
LEFT JOIN {{ ref('dim_bank') }} AS b ON f.bank_id = b.bank_id
LEFT JOIN {{ ref('dim_decline_reason') }} AS r
    ON coalesce(f.decline_reason, f.bank_decline_reason) = r.decline_reason
SETTINGS join_use_nulls = 1
