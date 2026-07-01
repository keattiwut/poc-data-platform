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

- [ ] `mock_data_producer` DAG runs daily, ahead of the extraction DAG, and performs an initial N-day backfill on first run
- [ ] Generator maintains ~3-5 Banks and ~5-10 Partners with stable, distinct profiles (auth rate, decline mix, fee schedule)
- [ ] A configurable low percentage of generated data is deliberately anomalous (orphan records, missing file, duplicate Transaction ID)
- [ ] `reset_mock_data` DAG/script wipes all five systems (mock DBs, SFTP, Kafka, lake, warehouse) and reseeds a fresh backfill on demand
- [ ] Default behavior across daily runs is append-only — reset never runs implicitly

## Blocked by

- 04-remaining-source-channels.md
