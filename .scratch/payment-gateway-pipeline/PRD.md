Status: ready-for-agent

# Payment Gateway Performance Data Pipeline (POC)

## Problem Statement

The company's Payment Gateway currently reports on company performance (transaction volume, approval rates, revenue) through a legacy crontab-based pipeline that isn't well operated. Data comes from multiple Bank and Partner systems via different channels (database, Excel, CSV, message queue), and there's no reliable, trustworthy way for stakeholders to review how the business — and each Bank/Partner channel — is actually performing. Nobody can confidently answer "how are we doing" without manually reconciling numbers across disconnected source systems.

## Solution

Build a modernized, fully open-source data platform that replaces the legacy crontab pipeline: it ingests Transaction data from Bank and Partner sources across all four channel types, reconciles the two sides of every transaction into a single trustworthy record, computes company performance metrics (volume, authorization rate, settlement rate, net/gross revenue, partner/bank comparison), and serves them through a BI dashboard — with the observability, security, and operational maturity a payment-adjacent system needs, even at POC stage.

## User Stories

### Business / dashboard review

1. As a business stakeholder, I want to see daily transaction Volume (Gross and Net), so that I can gauge overall Payment Gateway throughput.
2. As a business stakeholder, I want to see Authorization Rate, so that I know what fraction of initiated transactions get approved by the Bank.
3. As a business stakeholder, I want to see Settlement Rate separately from Authorization Rate, so that I can distinguish "approved" from "funds actually landed."
4. As a business stakeholder, I want to see Net Revenue alongside Gross Revenue, so that refunds/chargebacks don't make the business look more profitable than it is.
5. As a business stakeholder, I want to compare performance across Banks, so that I can see which processing rail performs best.
6. As a business stakeholder, I want to compare performance across Partners, so that I can see which origination channel performs best.
7. As a business stakeholder, I want to see Decline Reasons broken down per Bank/Partner, so that I understand *why* an approval rate is low, not just that it's low.
8. As a business stakeholder, I want to compare performance across time periods (week-over-week, month-over-month), so that I can see whether the business is trending up or down.
9. As a business stakeholder, I want the dashboard to reflect yesterday's data by the start of the business day, so that my morning review is never working off stale numbers.
10. As a business stakeholder, I want dashboards to load in a few seconds, so that reviewing performance doesn't feel sluggish.
11. As a business stakeholder, I want to access dashboards without a VPN when working remotely, so that I can review performance from anywhere.

### Pipeline mechanics

12. As a data engineer, I want a single orchestrator (Airflow) that replaces crontab, so that scheduling, retries, and backfills are reliable and observable.
13. As a data engineer, I want each of the four source types (database, Excel, CSV, message queue) extracted via a standard connector platform (Airbyte), so that I'm not maintaining bespoke extraction code per source.
14. As a data engineer, I want raw and cleaned data to land in a medallion-zoned data lake (bronze/silver), so that I have an auditable, replayable copy of source data independent of the warehouse.
15. As a data engineer, I want a Transaction's Bank-side and Partner-side records reconciled via a shared, gateway-assigned Transaction ID, so that I don't have to fuzzy-match records across sources.
16. As a data engineer, I want a Transaction to appear in the fact table as soon as either side reports it (full outer join), so that same-day volume isn't understated while the slower side catches up.
17. As a data engineer, I want the applied Fee Schedule rate captured on the Transaction at capture time, so that a future rate change never silently rewrites historical revenue.
18. As a data engineer, I want the fact table to be an accumulating snapshot (one row per Transaction, updated as it progresses), so that current-state queries stay simple and consistent with the no-SCD decision.
19. As a data engineer, I want dbt to build directly into ClickHouse from lake silver data, so that there's no separate gold-zone Parquet copy to keep in sync.
20. As a data engineer, I want fct_transactions backed by ClickHouse's ReplacingMergeTree engine with a dedicated `fct_transactions_current` dedup view, so that upserts work correctly and nobody has to remember to add FINAL to their queries.
21. As a data engineer, I want the incremental dbt model to re-scan a lookback window (not just rows since the last run), so that late-arriving milestones (e.g. a transaction that settles days after it's initiated) actually get picked up.
22. As a data engineer, I want conformed dimension tables (dim_bank, dim_partner, dim_decline_reason, dim_date) with surrogate keys, so that every dashboard reuses the same shared model instead of drifting per-dashboard business logic.

### Mock data

23. As a developer, I want a mock data generator that produces realistic, cross-source-correlated Transaction data (same Transaction ID appearing consistently on both the Bank and Partner sides), so that I can develop and demo the pipeline without real Bank/Partner access.
24. As a developer, I want the generator to run on the same daily cadence as the real pipeline (with an initial historical backfill), so that incremental logic and freshness checks are actually exercised, not just a one-shot dump.
25. As a developer, I want the generator to write into the real connector entry points (mock Postgres, mock SFTP files, mock Kafka topic), so that the mock data exercises the real Airbyte connectors, not a shortcut straight into the lake.
26. As a developer, I want the generator to inject a low, configurable rate of deliberate anomalies (orphan records, a missing file drop, duplicate Transaction IDs), so that the dbt tests, freshness checks, and alerting actually get proven to fire.
27. As a developer, I want a small fixed catalog of mock Banks and Partners, each with a stable profile (base authorization rate, Decline Reason mix, Fee Schedule), so that partner/bank comparison charts look meaningful.
28. As a developer, I want a reset capability that wipes and regenerates all mock data from scratch, so that I can get a clean slate for a new demo audience or dev iteration without manually clearing five different systems.

### Observability & operations

29. As a pipeline operator, I want system/infra metrics (Airflow, ClickHouse, MinIO) visible in Grafana, so that I can see service health without digging through logs.
30. As a pipeline operator, I want centralized, searchable logs (Loki) correlated with metrics, so that debugging a cross-service failure doesn't mean jumping between five different log sources.
31. As a pipeline operator, I want data freshness and quality failures (dbt tests, dbt source freshness) to route to a Critical alert channel, so that a broken pipeline is caught before a stakeholder sees stale/wrong dashboard numbers.
32. As a pipeline operator, I want non-blocking issues (a warn-severity test, disk usage trending up) routed to a separate Warning channel, so that critical alerts don't get lost in noise.
33. As a pipeline operator with no formal on-call rotation, I want a lightweight runbook linked from each alert, so that whoever responds doesn't have to reverse-engineer the failure from scratch.
34. As a pipeline operator, I want a source's schema drift (renamed/retyped/new columns) to fail loudly rather than auto-propagate, so that an unreviewed schema change can't silently corrupt revenue/volume numbers.

### Security & compliance

35. As a security reviewer, I want confirmation that no raw PAN or bank account number is ever stored anywhere in the pipeline, so that the platform stays out of PCI-DSS scope.
36. As a security reviewer, I want all service credentials centralized in HashiCorp Vault with audit logging, so that secrets aren't scattered across each tool's own config.
37. As a security reviewer, I want data encrypted at rest (MinIO, ClickHouse) and TLS used between every internal service, so that a compromised host doesn't trivially expose transaction data.
38. As a security reviewer, I want only Superset reachable from outside the internal network (with TLS, no default credentials, and login rate limiting), so that operator-only tools (Airflow, Grafana, MinIO console) aren't unnecessarily exposed.
39. As an internal staff member, I want dashboard access scoped to internal accounts with full visibility across all Banks/Partners, so that the access model matches the "internal performance review" use case without unnecessary complexity.

### Maintenance

40. As a platform owner, I want daily automated backups of MinIO, ClickHouse, the Airflow metadata DB, and Vault (to a separate location, ~24h RPO), so that a hardware failure on the self-hosted server doesn't mean total data loss.
41. As a contributor, I want every change to DAGs/dbt models/connector configs to go through a CI pipeline (lint + dbt build/test against dev) and required PR review, so that a broken change can't silently reach prod.

## Implementation Decisions

This PRD is downstream of 19 ADRs and a domain glossary (`CONTEXT.md`) already written to this repo (`docs/adr/0001` through `0019`). Key decisions, grouped by area:

**Pipeline shape**
- Daily batch pipeline; the message-queue source is treated as a periodically-drained source, not a streaming pipeline (no Kafka Streams/CDC-style continuous consumption).
- Self-hosted, on-prem infrastructure via Docker Compose; MinIO as the S3-API-compatible object store (no cloud provider dependency).
- Orchestrator: Apache Airflow. Extraction: Airbyte (covers all four source types — Postgres/MySQL via CDC, Kafka natively, Excel/CSV via SFTP-drop file source). Transform: dbt. Warehouse: ClickHouse. BI: Apache Superset.

**Lake and warehouse layering**
- Bronze (raw) and silver (cleaned) are Parquet zones on the lake; dbt staging models read from silver.
- There is no separate gold-zone Parquet output — dbt's intermediate and marts models materialize directly as ClickHouse tables. ClickHouse's mart tables *are* gold.
- `fct_transactions` is an accumulating-snapshot fact (one row per Transaction ID, milestone columns for initiated/authorized/captured/settled/failed/refunded), consistent with a current-state-only warehouse (no Type 2 SCD anywhere).
- Reconciliation joins Bank-side and Partner-side records on a gateway-assigned Transaction ID (generated at initiation, required to propagate to both sides) via a **full outer join** — a transaction is visible with null attributes on whichever side hasn't reported yet, rather than waiting for both sides to match.
- The transaction's fee (and the specific Fee Schedule rate applied) is calculated once at capture time and stored directly on the fact row — never recomputed later via a join to a "current rates" table.
- Conformed dimensions (`dim_bank`, `dim_partner`, `dim_decline_reason`, `dim_date`) use generated surrogate keys.
- `fct_transactions` is backed by ClickHouse's `ReplacingMergeTree` engine (ORDER BY Transaction ID) to realize dbt's incremental "merge" strategy, since ClickHouse has no true in-place UPDATE/MERGE. Because the raw table can transiently hold duplicate/stale rows before background deduplication runs, all consumers (Superset, downstream dbt models) query a dedicated `fct_transactions_current` view built with `argMax()` — nobody queries the raw table directly, and FINAL is not used ad hoc.
- The incremental dbt model uses `incremental_strategy: merge` with a lookback window (re-scanning the last several days of source data, not strictly "since last run"), specifically to catch late-arriving milestones.

**Domain model**
- **Transaction**: a payment attempt with a fixed lifecycle (initiated → authorized → captured → settled, plus failed/refunded terminal branches). Exactly one Bank and one Partner per transaction.
- **Bank**: the financial institution that authorizes/settles funds (the processing rail).
- **Partner**: the upstream entity (merchant/aggregator/PSP) that originates a transaction into the gateway.
- **Authorization Rate** and **Settlement Rate** are tracked as two distinct metrics, never collapsed into an ambiguous "success rate."
- **Fee Schedule**: fixed-fee + percentage pricing, varying per Partner/Bank pair.
- **Gross** vs **Net** Volume/Revenue: Net subtracts refunds/chargebacks from Gross; both are shown, Net is the headline figure.
- **Decline Reason**: a categorized cause (insufficient_funds, fraud_suspected, technical_error, invalid_account, etc.) attached to declined/failed transactions.
- Single currency only — no FX conversion in this POC.

**Mock data generation**
- A custom Python script (using Faker) owns the Transaction state-machine logic directly, generating correlated Bank-side and Partner-side views that share a Transaction ID and get written into the real mock Postgres DB / mock SFTP location / mock Kafka topic.
- Runs as its own `mock_data_producer` Airflow DAG on a daily cadence, plus an initial 30-90 day backfill.
- Demo-scale volume: ~1k-10k transactions/day.
- A small, low, configurable rate of deliberate anomalies (orphan records, a missing SFTP file drop, duplicate Transaction IDs) is injected to exercise the data-quality and alerting pipeline.
- Small fixed catalog: ~3-5 mock Banks, ~5-10 mock Partners, each with a stable profile (base authorization rate, Decline Reason mix, Fee Schedule).
- Append-only by default; a separate `reset_mock_data` DAG/script wipes and reseeds a fresh backfill on demand.
- The mock schema (field names, file layout) is a deliberately provisional placeholder — no real Bank/Partner integration spec exists yet, so rework of Airbyte configs and dbt staging models should be expected once real formats are known.

**Observability & operations**
- System metrics: Prometheus + Grafana (Airflow, ClickHouse, MinIO all expose native Prometheus endpoints), kept separate from Superset (which stays scoped to business BI).
- Logs: Grafana Loki (the "PLG stack").
- Data monitoring deliberately relies on dbt's built-in `source freshness` checks plus Airflow task success/failure — no dedicated data-observability tool (e.g. Elementary) for this POC.
- Alerts route to Microsoft Teams via two channels: **Critical** (extraction task failed, dbt build failed entirely, a warehouse/service unreachable, or a dbt error-severity test failed) and **Warning** (everything else non-blocking).
- No formal on-call rotation or paging tool; business-hours monitoring plus lightweight per-failure-mode runbooks linked from alerts.
- Source schema drift (new/renamed/retyped columns) is configured to **fail loudly** and route to Critical — this deliberately overrides Airbyte's default auto-propagation behavior.
- Daily backups (MinIO, ClickHouse, Airflow metadata DB, Vault) to a location separate from the host itself, ~24h RPO target.

**Security**
- No raw PAN or bank account number is ever stored anywhere in the pipeline — sources are required to send masked/tokenized identifiers only. This is a hard integration requirement to validate before connecting any future real Bank/Partner source, not a pipeline-side masking responsibility.
- All service credentials (DB, SFTP, Kafka, ClickHouse, MinIO) are centralized in HashiCorp Vault with audit logging — not Airflow's native Connections/Variables store.
- Encryption at rest (MinIO server-side encryption, encrypted ClickHouse volumes) and TLS between every internal service, built in from the start rather than deferred to a later hardening pass.
- Superset is the only UI reachable from outside the internal network (requires TLS, no default credentials, login rate limiting); Airflow, Grafana, and the MinIO console stay internal/VPN-only.
- Dashboard access is internal-staff-only with full visibility across all Banks/Partners — no row-level security by Partner in this POC. Auth is local accounts per tool, no SSO.

**Performance targets**
- Full daily pipeline (extraction → dbt → ClickHouse) must complete before business hours start (target: 6-8 AM).
- Dashboard charts should render in roughly 1-3 seconds at demo scale, achievable without pre-aggregated rollup tables.

## Testing Decisions

Two primary testing seams, chosen deliberately over relying on just one:

1. **dbt build/test against generator-produced fixtures.** The mock data generator's output for one simulated day is loaded as dbt seed fixtures standing in for the bronze/silver zone content, then `dbt build` runs and assertions are made directly against the resulting mart tables (`fct_transactions_current`, `dim_bank`, `dim_partner`, `dim_decline_reason`, `dim_date`). This is the fast, frequently-run seam and covers essentially all business logic: the Bank/Partner reconciliation join (including orphan/partial-row handling), fee-at-capture denormalization, the incremental merge/lookback behavior, the ReplacingMergeTree dedup view, dbt tests (not_null/unique/relationships/accepted_values), and dbt source freshness. Good tests here assert on the shape and values of the resulting mart rows (external behavior), not on intermediate dbt model internals.

2. **Full end-to-end Docker Compose integration tests.** A real Airflow DAG run against the actual Docker Compose stack (Airflow, Airbyte, MinIO, dbt, ClickHouse, Superset, Vault) proves the integration points the dbt-only seam can't reach: Airbyte connector configuration correctness (does the Postgres/Kafka/SFTP connector actually move bytes into bronze), Airflow scheduling/dependency wiring (the fan-out-then-dbt DAG shape), MinIO connectivity, and Vault-sourced credential wiring. Slower and more expensive than seam 1, but treated as a required primary seam, not an occasional smoke test, given how many real integration points (five+ services) exist between "generator runs" and "dashboard shows a number."

Because this repo is greenfield (no existing code, no prior test suite), there's no in-repo prior art to follow — these two seams establish the testing convention for everything that follows. Airbyte connector-level correctness and Superset chart rendering itself are treated as covered by seam 2's end-to-end assertions (does the expected data arrive in ClickHouse), not as separate dedicated test types.

## Out of Scope

- Real Bank/Partner integration. The mock schema is explicitly provisional; connecting a real source is a separate future effort once integration specs exist.
- Multi-currency / FX conversion — single currency only for this POC.
- Full transaction history / Type 2 SCD tracking — the warehouse is current-state-only throughout.
- Streaming or near-real-time ingestion — batch only, including for the message-queue source.
- Partner-facing dashboard access or row-level security by Partner — internal staff only, full visibility.
- Centralized SSO/OIDC authentication — local accounts per tool for this POC.
- Formal on-call rotation or paging tooling (PagerDuty/Opsgenie/Grafana OnCall) — business-hours monitoring only.
- A dedicated data-observability tool (e.g. Elementary) for anomaly/volume-drift detection beyond dbt tests and source freshness.
- Production-representative load/scale testing — mock data stays at demo scale (~1k-10k transactions/day).
- A gold-zone Parquet copy of curated data independent of ClickHouse.

## Further Notes

- All 19 ADRs referenced above live in `docs/adr/` and are the authoritative record of *why* each decision was made — this PRD summarizes them but the ADRs have the full reasoning, especially ADR-0009/0011/0012/0013/0014, which cover the trickiest parts of the reconciliation and warehouse design.
- The domain glossary in `CONTEXT.md` (Transaction, Bank, Partner, Fee Schedule, Gross/Net Volume/Revenue, Decline Reason, Critical/Warning alert) should be used consistently in code, issue titles, and dbt model names — avoid the terms explicitly listed under each glossary entry's `_Avoid_` line.
- A candidate vertical-slice breakdown (walking skeleton → reconciliation → remaining sources → full mock generator → dimensions/dashboard → data quality → observability → security → CI/backups) was drafted separately and can be turned into issues via `/to-issues` once this PRD is confirmed.
- The schema-fidelity risk (ADR-0010) is the single biggest known unknown in this whole PRD: real Bank/Partner formats aren't known yet, so expect staging-model and Airbyte-config rework once real integration specs appear.
