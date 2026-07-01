Status: ready-for-agent

# Conformed dimensions + full performance dashboard

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

With realistic multi-day, multi-anomaly data now flowing (previous issue), build out the full conformed dimensional model (ADR-0007) and complete the performance dashboard against all four pillars from the PRD.

Build `dim_bank`, `dim_partner`, `dim_decline_reason`, and `dim_date` as proper dbt models with surrogate keys (`dim_date` needs calendar attributes — week/month/quarter/year — to support period comparisons). Wire `fct_transactions_current` to join against these shared dimensions rather than any dashboard re-deriving its own bank/partner/date logic.

Extend the Superset dashboard to cover all four performance pillars from the PRD: Volume (Gross and Net), Authorization Rate and Settlement Rate, Net and Gross Revenue, and Bank/Partner comparison — plus Decline Reason breakdown per Bank/Partner, and week-over-week / month-over-month period comparison using `dim_date`.

## Acceptance criteria

- [ ] `dim_bank`, `dim_partner`, `dim_decline_reason`, `dim_date` exist as dbt models with surrogate keys; `dim_date` includes week/month/quarter/year attributes
- [ ] `fct_transactions_current` (or a mart built on it) joins to all four dimensions rather than embedding bank/partner/date logic ad hoc
- [ ] Dashboard shows Gross and Net Volume, Authorization Rate, Settlement Rate, Gross and Net Revenue, and a Bank/Partner comparison view
- [ ] Dashboard shows Decline Reason breakdown per Bank/Partner
- [ ] Dashboard supports at least one period-over-period comparison (week-over-week or month-over-month) using `dim_date`
- [ ] All dashboard charts render in roughly 1-3 seconds at demo-scale data volume

## Blocked by

- 05-full-mock-data-generator.md
