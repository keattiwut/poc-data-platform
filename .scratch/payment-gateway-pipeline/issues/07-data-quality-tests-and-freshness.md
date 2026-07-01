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

- [ ] `not_null`/`unique` tests exist on Transaction ID and every dimension surrogate key
- [ ] `relationships` tests validate every fact-to-dimension foreign key
- [ ] `accepted_values` tests constrain Transaction lifecycle state and Decline Reason to their defined sets
- [ ] `source freshness` is configured on every source table with a threshold that would breach before the 6-8 AM SLA window closes
- [ ] Running the pipeline against generator output with a known injected anomaly causes the corresponding test to fail (demonstrated, not just configured)

## Blocked by

- 06-dimensions-and-full-dashboard.md
