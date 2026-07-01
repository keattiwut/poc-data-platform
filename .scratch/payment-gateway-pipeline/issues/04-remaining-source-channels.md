Status: ready-for-agent

# Add remaining source channels: SFTP Excel/CSV + Kafka

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Complete the four-source-type requirement from the PRD. So far only database sources (Bank-side and Partner-side Postgres) exist; add the two file-based channels and the message-queue channel.

Extend the mock generator so that a portion of Transactions arrive via an Excel or CSV file dropped to a mock SFTP location (ADR: SFTP file delivery), and a portion arrive via messages published to a mock Kafka topic (ADR-0001: Kafka is treated as a periodically-drained batch source, not consumed continuously — messages are pulled on the same daily schedule as the other sources, not streamed).

Wire the corresponding Airbyte connectors (File source pointed at the SFTP location; Kafka source) into the same bronze/silver/staging pipeline used for the database sources, and fold their output into the same reconciled `fct_transactions` model — a Transaction's Bank-side or Partner-side data may now originate from any of the four channel types, and the reconciliation logic from the previous issue should require no changes to accommodate this (the join is on Transaction ID, not on source channel).

## Acceptance criteria

- [ ] Mock generator produces a portion of Transactions via an SFTP-dropped Excel or CSV file
- [ ] Mock generator produces a portion of Transactions via a mock Kafka topic, drained on the daily batch schedule (not streamed)
- [ ] Airbyte File source and Kafka source connectors are configured and syncing into bronze
- [ ] `fct_transactions` reconciles Transactions regardless of which of the four channel types either side arrived through
- [ ] Dashboard volume/rate numbers reflect Transactions from all four source channels combined

## Blocked by

- 03-bank-side-reconciliation-and-fee-revenue.md
