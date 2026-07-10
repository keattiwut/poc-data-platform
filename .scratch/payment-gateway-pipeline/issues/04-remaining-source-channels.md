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

- [ ] Mock generator produces a portion of Transactions via an SFTP-dropped Excel or CSV file
- [ ] Mock generator produces a portion of Transactions via a mock Kafka topic, drained on the daily batch schedule (not streamed)
- [ ] All four source channels are extracted by dlt tasks inside `daily_pipeline` (no Airbyte); bronze layout contract preserved
- [ ] Kafka drain has a dedicated smoke test (the thinnest square in the ADR-0024 evidence matrix)
- [ ] Airbyte, abctl, the kind cluster, and all airbyte-* scripts are removed; README updated; no credential lives outside the Vault render
- [ ] `fct_transactions` reconciles Transactions regardless of which of the four channel types either side arrived through
- [ ] Dashboard volume/rate numbers reflect Transactions from all four source channels combined

## Blocked by

- 03-bank-side-reconciliation-and-fee-revenue.md
