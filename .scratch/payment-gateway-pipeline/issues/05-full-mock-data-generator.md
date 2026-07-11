Status: ready-for-agent

# Full mock data generator: scheduled DAG, backfill, anomalies, catalog

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Upgrade the minimal, manually-run mock generator from previous issues into the full generator described in ADR-0010.

Move the generator into its own `mock_data_producer` Airflow DAG, scheduled daily ahead of the real extraction DAG. On first run, seed a 30-90 day historical backfill so the dashboard has trend history immediately; subsequent runs append one new simulated day at demo scale (~1k-10k transactions/day).

Introduce a small fixed catalog of ~3-5 mock Banks and ~5-10 mock Partners, each with a stable profile: a base Authorization Rate, a Decline Reason mix (insufficient_funds, fraud_suspected, technical_error, invalid_account, etc. — CONTEXT.md), and a Fee Schedule, held consistent across simulated days.

Inject a small, configurable rate of deliberate anomalies: orphan records (one side reports, the other never does), an occasional missing SFTP file drop, and duplicate Transaction IDs — specifically so the dbt tests, freshness checks, and alerting built in later issues have something real to catch.

Build a separate `reset_mock_data` DAG/script that wipes the mock Postgres DB(s), SFTP directory, Kafka topic, lake zones, and warehouse, then reseeds a fresh backfill — for demo resets or a clean dev-iteration slate. Keep the generator append-only by default; reset is opt-in.

## Acceptance criteria

- [x] `mock_data_producer` DAG runs daily, ahead of the extraction DAG, and performs an initial N-day backfill on first run
- [x] Generator maintains ~3-5 Banks and ~5-10 Partners with stable, distinct profiles (auth rate, decline mix, fee schedule)
- [x] A configurable low percentage of generated data is deliberately anomalous (orphan records, missing file, duplicate Transaction ID)
- [x] `reset_mock_data` DAG/script wipes all five systems (mock DBs, SFTP, Kafka, lake, warehouse) and reseeds a fresh backfill on demand
- [x] Default behavior across daily runs is append-only — reset never runs implicitly

## Blocked by

- 04-remaining-source-channels.md

## Comments

**2026-07-11 (agent):** Implemented on branch `issue-05-full-mock-generator`.

- `mock/generate_transactions.py` rewritten: fixed catalog of 6 Partners / 4 Banks with stable profiles (channel, volume weight, base auth rate + per-bank modifier, per-bank decline mix); `--day`/`--backfill`/`--backfill-if-empty` modes; anomaly knobs `MOCK_ORPHAN_RATE` (0.10), `MOCK_DUPLICATE_RATE` (0.02, SFTP/Kafka only — the Postgres PK would swallow them), `MOCK_MISSING_FILE_RATE` (0.05). Fee-schedule seed expanded to all 24 pairs.
- `mock_data_producer` DAG at 00:00; `daily_pipeline` moved to 02:00 ("scheduled ahead" contract). Airflow 3 gotcha: manual runs have no logical date (`ds` renders undefined) — the template falls back to wall-clock date.
- `reset_mock_data` DAG (manual-only) → `scripts/reset-mock-data.py` wipes mock Postgres, SFTP uploads, Kafka topics, **dlt offset state** (topic deletion resets broker offsets below dlt's remembered ones — without wiping state the next drain would silently skip everything forever), lake zones, warehouse; then reseeds backfill and triggers `daily_pipeline`. Two MinIO/library gotchas fixed: bulk `DeleteObjects` fails against MinIO (MissingContentMD5) → per-object deletes; `delete_topics([])` raises.
- Verified live: first producer run backfilled 45×1500=67.5k; second run appended one day only (20,420→20,825 pg rows); reset DAG green end-to-end, rebuilt dashboard sum (67,368) matches `fct_transactions_current`; 870 duplicates in bronze, silver fully deduped; missing-file anomalies fired ~6.7%; partner auth-rate spread 0.21. New `scripts/verify-mock-producer.sh` checks backfill depth, catalog coverage, profile distinctness, and fee-pair coverage.
