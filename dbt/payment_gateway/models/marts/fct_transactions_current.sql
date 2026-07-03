{{ config(materialized='view') }}

-- NOTE: source columns are qualified via the `ft` alias below. ClickHouse's
-- alias substitution otherwise rewrites bare `updated_at` references inside
-- the argMax(...) calls to the `max(updated_at) AS updated_at` output alias,
-- producing "aggregate function is found inside another aggregate function".
SELECT
    ft.transaction_id,
    argMax(ft.partner_id, ft.updated_at)      AS partner_id,
    argMax(ft.amount_cents, ft.updated_at)    AS amount_cents,
    argMax(ft.currency, ft.updated_at)        AS currency,
    argMax(ft.state, ft.updated_at)           AS state,
    argMax(ft.decline_reason, ft.updated_at)  AS decline_reason,
    argMax(ft.initiated_at, ft.updated_at)    AS initiated_at,
    argMax(ft.authorized_at, ft.updated_at)   AS authorized_at,
    argMax(ft.captured_at, ft.updated_at)     AS captured_at,
    argMax(ft.settled_at, ft.updated_at)      AS settled_at,
    argMax(ft.failed_at, ft.updated_at)       AS failed_at,
    argMax(ft.refunded_at, ft.updated_at)     AS refunded_at,
    argMax(ft.bank_id, ft.updated_at)         AS bank_id,
    argMax(ft.bank_authorized_at, ft.updated_at) AS bank_authorized_at,
    argMax(ft.bank_captured_at, ft.updated_at)   AS bank_captured_at,
    argMax(ft.bank_settled_at, ft.updated_at)    AS bank_settled_at,
    max(ft.updated_at)                        AS updated_at
FROM {{ ref('fct_transactions') }} AS ft
GROUP BY ft.transaction_id
