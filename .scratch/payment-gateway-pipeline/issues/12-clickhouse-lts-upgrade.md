Status: ready-for-agent

# Upgrade ClickHouse to current LTS; retire s3-view join workaround if repro passes

## Parent

`review_recommendation.md` (findings 2, 5) · `docs/adr/0022-clickhouse-lts-upgrade.md`

## What to build

The stack pins `clickhouse-server:24.10`, a non-LTS release with a verified bug (documented in `int_reconciled_transactions.sql`): joins against `s3()`-backed views silently NULL an unpredictable subset of columns. The workaround snapshots staging views into physical `int_partner_transactions` / `int_bank_transactions` tables — two extra full data copies per run.

Bump the image to a current ClickHouse LTS. Write a standalone repro script (`scripts/verify-clickhouse-s3-join-bug.sh`) that joins the `s3()`-backed staging views directly and checks the previously-affected columns (`bank_id`, `decline_reason`, `bank_decline_reason`) for silent NULLs on rows known to match. **Only if the repro passes on the new version**: delete the two `int_*` snapshot models and point `int_reconciled_transactions` at the staging views directly. If it still fails, keep the workaround and record the tested version in ADR-0022.

Also fix the ADR-0014 drift (finding 5): the ADR describes `incremental_strategy: merge` with a lookback window, but `fct_transactions` is `materialized='table'` (full rebuild). Amend ADR-0014 with a one-line note that full-rebuild is the current implementation and incremental+lookback is the plan once volume warrants it.

## Acceptance criteria

- [ ] `docker-compose.yml` pins a current ClickHouse LTS version
- [ ] A repro script exists that exercises the s3-view join bug and fails loudly on silent NULLs
- [ ] Workaround models deleted **only** with a passing repro on the running upgraded instance; otherwise retained with ADR-0022 updated to record the result
- [ ] `verify-fct-transactions.sh` and `verify-dbt.sh` pass after the change
- [ ] ADR-0014 amended to state the current full-rebuild reality

## Blocked by

- 11-airflow-3-and-first-dag.md (avoid concurrent docker-compose.yml edits; requires a running stack to verify)
