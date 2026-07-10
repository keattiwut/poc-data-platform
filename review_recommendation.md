# Project Review & Recommendations

Date: 2026-07-09 · Scope: full repo as of commit `2b7f5a1` (Issue 03 complete, Issues 04–10 pending)

## Verdict

The project is in unusually good shape for a POC: 20 ADRs with real rationale, a domain vocabulary (`CONTEXT.md`) that the models actually follow, per-component verify scripts plus a full-stack one, secrets that genuinely originate from Vault, and dbt model comments that record findings *verified against the running instance* (the ClickHouse s3-view join bug notes are exemplary). Nothing here is broken. The recommendations below are about (a) drift between what the ADRs/architecture claim and what's implemented, and (b) four stack decisions worth revisiting **now**, while they're still cheap to change — each is written up as a proposed ADR.

## Findings

Ranked by impact. "ADR" links are new **Proposed** ADRs in `docs/adr/` — they're recommendations, not accepted decisions.

### 1. Airflow is deployed but orchestrates nothing — and it's the wrong major version to start on

`airflow/dags/` contains only `.gitkeep`. Three Airflow containers (init, webserver, scheduler) run so that shell scripts can do the actual pipeline work by hand. That's expected mid-backlog, but two consequences follow:

- **The single riskiest unbuilt piece is orchestration**, not more sources. PRD story 12 ("replace crontab") is the project's founding motivation, and today the pipeline is effectively *scripts run by a human* — the very thing being replaced. Recommend pulling DAG wiring forward (before or alongside Issue 04) so every new source lands orchestrated instead of accreting more manual steps to migrate later.
- **The stack pins Airflow 2.10.3, one major behind.** Airflow 3 has been GA since April 2025; 2.x is in wind-down. Since zero DAGs exist, adopting Airflow 3 now costs almost nothing, while migrating written DAGs later costs real work. → [ADR-0021](docs/adr/0021-airflow-3-before-first-dag.md)

### 2. ClickHouse 24.10 bug forces extra materialization layers — upgrade and delete the workaround

`int_reconciled_transactions.sql` and `fct_transactions.sql` document a real ClickHouse 24.10.4 bug (joins against `s3()`-backed views silently NULL random columns), worked around by snapshotting each staging view into a physical `int_*` table before joining. That's two extra full copies of the data per run plus permanent "don't touch this" complexity. 24.10 is a non-LTS release; current LTS lines exist well past it. Recommend upgrading to a current LTS, re-running the documented repro, and deleting `int_partner_transactions` / `int_bank_transactions` if the bug is gone. → [ADR-0022](docs/adr/0022-clickhouse-lts-upgrade.md)

### 3. Vault dev mode's restart hazard is cheap to remove

The README's longest section is a warning that a Vault container restart silently wipes all secrets and requires `docker compose down -v` (destroying **all data volumes**) to recover. Switching Vault from dev mode to its `file` storage backend removes that entire failure mode for roughly 20 lines of config. → [ADR-0023](docs/adr/0023-vault-file-storage-backend.md)

### 4. Airbyte is the heaviest component in the stack and sits outside Vault

Airbyte-via-`abctl` runs an entire kind Kubernetes cluster to serve four known, simple source types — and its credentials are an accepted gap in Vault coverage (README). Before Issue 04 invests in three more Airbyte connectors, decide deliberately whether a Python-native extraction library (dlt) running *as Airflow tasks* is a better fit: no k8s cluster, credentials from the same Vault render step, extraction code versioned in this repo. This reverses accepted ADR-0020, so it's proposed, not assumed. → [ADR-0024](docs/adr/0024-dlt-instead-of-airbyte.md)

### 5. ADR-0014 describes an incremental strategy that isn't implemented

ADR-0014 specifies `incremental_strategy: merge` with a lookback window for `fct_transactions`, but the model is `materialized='table'` — a full rebuild every run. Full rebuild is *fine* (arguably better) at POC data volume, but the ADR reads as current fact. Recommend a one-line amendment to ADR-0014 noting "full-rebuild for now; switch to incremental when volume warrants," so nobody debugs a lookback window that doesn't exist.

### 6. Bronze→silver promotion is a third engine, unorchestrated, with hardcoded plumbing

`scripts/promote-bronze-to-silver.py` introduces DuckDB alongside ClickHouse and Postgres, runs only by hand, hardcodes `localhost:9000` as the MinIO endpoint (breaks the moment it runs inside a container as an Airflow task), and rewrites the whole silver zone as a single `data.parquet` per table (full O(bronze) rewrite each run — fine now, a known ceiling). Keeping DuckDB is defensible (it's genuinely good at Parquet-over-S3), but: parametrize the endpoint, and fold the script into the DAG when orchestration lands (finding 1). If the ClickHouse upgrade (finding 2) fixes the s3-view bug, evaluate whether silver promotion can just become a dbt model and DuckDB can be deleted.

### 7. Everything talks to MinIO as root

The ClickHouse named collection, the DuckDB promotion script, and Airbyte all use `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`. Vault stores the secret, but it's still one god-credential. Per-service MinIO users (read-only bronze for dbt/ClickHouse, write-silver for the promoter, write-bronze for extraction) is a natural addition to Issue 09 (security hardening) — no new ADR needed, ADR-0006's intent already covers it.

## Recommendation summary

| # | Recommendation | Effort | Where |
|---|---|---|---|
| 1 | Wire the first DAG before adding sources; start on Airflow 3 | Medium | ADR-0021, reorder backlog |
| 2 | Upgrade ClickHouse to current LTS; delete `int_*` snapshot workaround if repro passes | Small | ADR-0022 |
| 3 | Vault `file` storage backend instead of dev mode | Small | ADR-0023 |
| 4 | Decide dlt vs. Airbyte before Issue 04 builds 3 more connectors | Medium | ADR-0024 |
| 5 | Amend ADR-0014 to note full-rebuild is the current reality | Trivial | docs edit |
| 6 | Parametrize promotion endpoint; orchestrate it; revisit DuckDB after #2 | Small | with finding 1 |
| 7 | Per-service MinIO credentials | Small | fold into Issue 09 |

## What NOT to change

- **Batch over streaming (ADR-0001), no SCD (ADR-0005), denormalized fee (ADR-0011), full outer join reconciliation (ADR-0012), dedup view over FINAL (ADR-0014's view part)** — all correctly sized for the problem; leave them alone.
- **The 20+ verify scripts** — they look like sprawl but each is a runnable check tied to a task; `verify-full-stack.sh` already composes them. Consolidating would lose granularity for zero gain.
- **Single Postgres with three databases** — right call at this scale, already documented.
