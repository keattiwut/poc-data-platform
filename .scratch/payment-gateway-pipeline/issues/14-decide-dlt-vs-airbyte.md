Status: ready-for-agent

# Decide: dlt vs Airbyte for extraction (before Issue 04)

## Parent

`review_recommendation.md` (finding 4) · `docs/adr/0024-dlt-instead-of-airbyte.md`

## What to build

A decision spike, not a migration. Airbyte-via-abctl is the heaviest stack component (a whole kind Kubernetes cluster) and the only credential domain outside Vault, serving four known simple source types. ADR-0024 proposes replacing it with dlt running as Airflow tasks. This must be decided **before Issue 04** builds three more Airbyte connectors — one connector is cheap to rewrite, four are sticky.

Produce the evidence to accept or reject ADR-0024:

1. Verify dlt's current support for each needed source: Postgres (`sql_database`), SFTP-dropped CSV/Excel (`filesystem`), Kafka — and Parquet-to-S3(MinIO) as the bronze-zone destination. Cite current docs, not training memory.
2. Write a small prototype: a dlt pipeline script extracting `partner_transactions` from the mock Postgres into bronze-zone Parquet on MinIO, matching the layout Airbyte produces today (runnable when the stack is up; commit it under `mock/` or `scripts/` as a spike artifact).
3. Compare operational weight honestly: image/memory footprint, credential path (Vault render vs Airbyte-internal), upgrade story, and what is lost (connector UI, catalog).
4. Update ADR-0024's status to Accepted or Rejected with the findings, and update Issue 04 to match the outcome (dlt tasks vs Airbyte connectors).

## Acceptance criteria

- [x] Source-by-source support matrix with citations to current dlt docs (2026-07-09 spike — see "Evidence" section appended to ADR-0024)
- [x] Prototype dlt script exists and is documented (`scripts/spike-dlt-partner-extraction.py` — **verified 2026-07-10**: ran unmodified against the live stack, 196 rows → Parquet on MinIO)
- [x] ADR-0024 status changed from Proposed with rationale recorded — **Accepted by the maintainer 2026-07-10** on the spike evidence (verified prototype run + observed Airbyte data-loss incident on Docker restart)
- [x] Issue 04 amended to reflect the decision — rewritten for dlt tasks, including migrating the two existing Postgres connections and retiring Airbyte/abctl/kind

**Done (2026-07-10).** Follow-through lives in Issue 04.

## Blocked by

- (nothing — but its outcome gates 04-remaining-source-channels.md)
