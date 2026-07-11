Status: ready-for-agent

# Conformed dimensions + full performance dashboard

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

With realistic multi-day, multi-anomaly data now flowing (previous issue), build out the full conformed dimensional model (ADR-0007) and complete the performance dashboard against all four pillars from the PRD.

Build `dim_bank`, `dim_partner`, `dim_decline_reason`, and `dim_date` as proper dbt models with surrogate keys (`dim_date` needs calendar attributes — week/month/quarter/year — to support period comparisons). Wire `fct_transactions_current` to join against these shared dimensions rather than any dashboard re-deriving its own bank/partner/date logic.

Extend the Superset dashboard to cover all four performance pillars from the PRD: Volume (Gross and Net), Authorization Rate and Settlement Rate, Net and Gross Revenue, and Bank/Partner comparison — plus Decline Reason breakdown per Bank/Partner, and week-over-week / month-over-month period comparison using `dim_date`.

## Acceptance criteria

- [x] `dim_bank`, `dim_partner`, `dim_decline_reason`, `dim_date` exist as dbt models with surrogate keys; `dim_date` includes week/month/quarter/year attributes
- [x] `fct_transactions_current` (or a mart built on it) joins to all four dimensions rather than embedding bank/partner/date logic ad hoc
- [x] Dashboard shows Gross and Net Volume, Authorization Rate, Settlement Rate, Gross and Net Revenue, and a Bank/Partner comparison view
- [x] Dashboard shows Decline Reason breakdown per Bank/Partner
- [x] Dashboard supports at least one period-over-period comparison (week-over-week or month-over-month) using `dim_date`
- [x] All dashboard charts render in roughly 1-3 seconds at demo-scale data volume

## Blocked by

- 05-full-mock-data-generator.md

## Comments

**2026-07-11 (agent):** Implemented on branch `issue-06-dimensions-dashboard`.

- Four conformed dims (ADR-0007) with deterministic `cityHash64` surrogate keys (stable across dbt full rebuilds, no sequence state); `dim_date` is a 3-year calendar (day-of-week/week/ISO-week/month/quarter/year). MergeTree gotcha: sorting keys reject Nullable columns → `assumeNotNull` on the filtered natural keys.
- `mart_transactions` view joins the fact to all four dims (`join_use_nulls = 1`, same default-fill trap as fct). Had to use an explicit column list — `f.*` plus joins makes ClickHouse name view columns literally `f.bank_id`, which broke Superset's dataset column sync.
- Superset config ported from bash to `scripts/configure-superset-dashboard.py` (idempotent; also refreshes dataset column metadata — Superset validates charts against its cached copy). 12 charts across the four PRD pillars incl. Weekly Gross-vs-Net (WoW via `dim_date.week_start`), Volume + Decline-Reason breakdowns by Bank/Partner; new "Payment Gateway Performance" dashboard, superseded "Transaction Volume" dashboard deleted.
- Verified live: all 12 charts return correct shapes (4 banks / 6 partners / 16 & 24 decline rows) in ~1.2–1.3 s each at 67k rows (budget 3 s, asserted by the extended `verify-superset-chart.sh`); full walking-skeleton green end-to-end.
