Status: ready-for-agent

# Walking skeleton: one source (mock Partner DB) → dashboard

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Prove the entire pipeline path end-to-end using the thinnest possible slice: a single source, no reconciliation yet.

Build a minimal version of the mock data generator (just enough for this slice, not the full ADR-0010 spec) that produces Partner-side Transaction records into a mock Postgres database — Transactions with a gateway-assigned Transaction ID, moving through the initiated → authorized → captured → settled lifecycle (plus failed/refunded branches) per the domain model in `CONTEXT.md`.

Wire an Airbyte Postgres connector to extract this into the lake's bronze zone, promote to silver, and build dbt staging + a minimal `fct_transactions` model (Partner-side populated, Bank-side columns left null — this is intentional and consistent with the full-outer-join reconciliation design in ADR-0012, even though Bank-side data doesn't exist yet in this slice). Materialize the fact using the `ReplacingMergeTree` engine with a `fct_transactions_current` dedup view (ADR-0014), loaded directly into ClickHouse (ADR-0013 — no separate gold Parquet zone).

Build one Superset chart: transaction volume by day, reading from `fct_transactions_current`.

Run this manually or via a simple Airflow DAG — the full daily-scheduled generator and fan-out DAG shape come in later issues.

## Acceptance criteria

- [ ] Mock generator produces Partner-side Transaction records with a valid gateway-assigned Transaction ID and a plausible lifecycle
- [ ] Airbyte syncs the mock Postgres source into lake bronze, and a cleaning step promotes it to silver
- [ ] dbt staging model reads from silver; a minimal `fct_transactions` model builds with Bank-side columns present but null
- [ ] `fct_transactions` uses ReplacingMergeTree; `fct_transactions_current` view returns deduplicated rows via `argMax()`
- [ ] A Superset chart displays transaction volume by day, sourced from `fct_transactions_current`
- [ ] The full path (generator → Airbyte → lake → dbt → ClickHouse → Superset) is demoable in one run

## Blocked by

- 01-infra-bootstrap.md
