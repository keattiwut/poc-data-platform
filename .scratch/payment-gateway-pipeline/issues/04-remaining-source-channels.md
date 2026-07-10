Status: ready-for-agent

# Add remaining source channels via dlt: SFTP Excel/CSV + Kafka, and retire Airbyte

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Complete the four-source-type requirement from the PRD. So far only database sources (Bank-side and Partner-side Postgres) exist; add the two file-based channels and the message-queue channel.

Extend the mock generator so that a portion of Transactions arrive via an Excel or CSV file dropped to a mock SFTP location (ADR: SFTP file delivery), and a portion arrive via messages published to a mock Kafka topic (ADR-0001: Kafka is treated as a periodically-drained batch source, not consumed continuously — messages are pulled on the same daily schedule as the other sources, not streamed).

Extraction uses **dlt, not Airbyte** (ADR-0024, accepted 2026-07-10, superseding ADR-0020): each source is a small dlt pipeline running as an Airflow task in `daily_pipeline`, writing Parquet to the bronze zone with the same layout contract Airbyte used. `scripts/spike-dlt-partner-extraction.py` is the verified starting template. Concretely: the SFTP-dropped Excel/CSV channel uses dlt's `filesystem` source (`sftp://` bucket_url; Excel needs the small documented pandas transformer), and Kafka uses the `kafka_consumer` verified source copied into the repo via `dlt init` — drain it as a batch on the daily schedule and give it a smoke test first, it's the least-mature square in the Issue 14 matrix. Fold their output into the same silver/staging pipeline; the reconciliation logic from the previous issue should require no changes (the join is on Transaction ID, not on source channel).

As part of this issue, migrate the two existing Airbyte Postgres connections (Partner DB, Bank DB) to dlt tasks and **retire Airbyte entirely**: delete `scripts/install-airbyte.sh`, the `configure-airbyte-*.sh` / `verify-airbyte*.sh` scripts, and the kind cluster (`abctl local uninstall`), and update the README's Airbyte/Vault-gap section — after this, every credential in the platform comes from the Vault render (closing the ADR-0006 gap).

## Acceptance criteria

- [x] Mock generator produces a portion of Transactions via an SFTP-dropped Excel or CSV file
- [x] Mock generator produces a portion of Transactions via a mock Kafka topic, drained on the daily batch schedule (not streamed)
- [x] All four source channels are extracted by dlt tasks inside `daily_pipeline` (no Airbyte); bronze layout contract preserved
- [x] Kafka drain has a dedicated smoke test (the thinnest square in the ADR-0024 evidence matrix)
- [x] Airbyte, abctl, the kind cluster, and all airbyte-* scripts are removed; README updated; no credential lives outside the Vault render *(scripts/docs done; `abctl local uninstall` itself pending maintainer confirmation, see comment)*
- [x] `fct_transactions` reconciles Transactions regardless of which of the four channel types either side arrived through
- [x] Dashboard volume/rate numbers reflect Transactions from all four source channels combined

## Blocked by

- 03-bank-side-reconciliation-and-fee-revenue.md

## Comments

**2026-07-11 (agent):** Implemented on branch `issue-04-dlt-source-channels` (commits `529b1fc` extraction, `6f11a09` docs; the SFTP/Kafka infra + generator routing commits were already on the branch).

- `scripts/extract-to-bronze.py`: one dlt pipeline per channel, run as four Airflow tasks upstream of the promotions. Kafka verified source vendored at `scripts/kafka_source/` (copied by hand from dlt-hub/verified-sources `3957506` — host Python 3.14 predates dlt, so `dlt init` couldn't run; same files).
- Bronze layout is `bronze/<channel_dataset>/<table>/*.parquet` (dlt always inserts its dataset dir, so the literal Airbyte `bronze/<table>/` path was not reproducible); the promotion script now globs `bronze/*/<table>/**` and promotes an explicit column list. Silver and everything downstream unchanged — the reconciliation join needed no changes, as predicted.
- Verified end-to-end against the live stack: `daily_pipeline` run green (4 extracts → 2 promotes → dbt build), `verify-kafka-drain.sh` passes (incl. offset-tracking assertion: second drain loads 0), `verify-dlt-bronze.sh` shows both tables arriving via 3 channel datasets each, day-of-run reconciliation rate 0.91 (≈ the designed 10% orphan rate), Superset charts sum (1413) matches `fct_transactions_current`.
- Fixed en route: seeded SFTP secret was the inconsistent `sftp:2222` host/port hybrid → now in-network `sftp:22` (existing Vault value updated in place); SFTP host port remapped 2222→12222 (2222 fell into a Windows excluded-port range after reboot).
- Note: the old Jul 4–5 mock batches reconcile at only ~0.17 in `fct` — those generator runs predate the SFTP upload-permission fix, so their SFTP-routed rows never existed. Mock-data artifact, not an extraction bug.
- **Open:** `abctl local uninstall` (kind cluster teardown) was blocked by the agent-permission gate as a destructive action on a pre-existing resource; needs the maintainer to run/confirm it. Nothing in the repo references Airbyte anymore.
