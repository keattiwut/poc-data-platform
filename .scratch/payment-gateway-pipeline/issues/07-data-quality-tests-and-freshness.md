Status: ready-for-agent

# Data quality: dbt tests + source freshness

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Add dbt's built-in testing framework across the staging, intermediate, and marts models: `not_null` and `unique` on primary/foreign keys (especially Transaction ID and the dimension surrogate keys), `relationships` tests validating every fact-to-dimension join, and `accepted_values` on enumerated fields (Transaction lifecycle state, Decline Reason).

Add dbt `source freshness` checks on every source table, with thresholds tied to the pipeline SLA from the PRD: the daily pipeline must complete before business hours start (6-8 AM), so a freshness check breach should be detectable well before that window closes.

This issue deliberately does not add a dedicated data-observability tool (e.g. Elementary) — dbt tests and source freshness are the full extent of data monitoring for this POC (PRD "Out of Scope").

Use the anomalies injected by the mock generator (issue 05) to prove these tests actually catch something: run the pipeline against generator output containing an orphan record, a missing file, or a duplicate Transaction ID, and confirm the relevant test fails.

## Acceptance criteria

- [x] `not_null`/`unique` tests exist on Transaction ID and every dimension surrogate key
- [x] `relationships` tests validate every fact-to-dimension foreign key
- [x] `accepted_values` tests constrain Transaction lifecycle state and Decline Reason to their defined sets
- [x] `source freshness` is configured on every source table with a threshold that would breach before the 6-8 AM SLA window closes
- [x] Running the pipeline against generator output with a known injected anomaly causes the corresponding test to fail (demonstrated, not just configured)

## Blocked by

- 06-dimensions-and-full-dashboard.md

## Comments

**2026-07-11 (agent):** Implemented on branch `issue-07-data-quality`.

- 38 tests: uniqueness lives on `fct_transactions_current` (not the ReplacingMergeTree fact, which holds multiple versions between merges); relationships on all four mart→dim keys (NULL-exempt semantics fit the outer-join model); accepted_values on state + decline reason both sides.
- Freshness: silver zone declared as a dbt source via the stg views (1:1 windows onto silver; all four channels converge there). warn 4h / error 8h — healthy 02:00 runs have age ≤ 0 (mock timestamps run ahead of the clock); a missed run warns by 04:00, errors at 08:00. Runs as `dbt_source_freshness` beside `dbt_build` in `daily_pipeline`.
- Anomaly demo (`scripts/verify-dq-tests.sh`): promoting with `PROMOTE_SKIP_DEDUP=1` lets the generator's real duplicate-ID anomaly through and `unique_stg_partner_transactions_transaction_id` fails; normal re-promotion restores green. Verified live: dbt build 49/49, DQ script full pass, DAG run green with all 8 tasks.
