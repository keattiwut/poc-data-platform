# Mock data generation strategy for the POC

Since no real Bank/Partner data access exists yet, a custom Python script (using Faker for realistic names/amounts/timestamps) generates mock data that owns the Transaction state-machine logic directly: it creates a batch of Transactions sharing a gateway-assigned ID, walks each through the initiated→authorized→captured→settled lifecycle (or a decline/refund branch) with realistic probabilities, then emits a Bank-side view to the mock Postgres DB / mock SFTP Excel-CSV drop / mock Kafka topic as appropriate, and a Partner-side view likewise — so the data exercises the actual Airbyte connectors rather than being seeded directly into the lake.

This was chosen over static `dbt seed` fixtures (which can't represent a new realistic day of data and wouldn't exercise incremental/freshness logic) and over a dedicated synthetic-data tool like SDV/Mockaroo (which aren't well-suited to hand-modeling a specific cross-source correlated state machine).

Key parameters:

- **Cadence**: runs on the same daily schedule as the real pipeline, plus an initial backfill (30-90 simulated days) so the dashboard has trend history from day one — this is what actually exercises incremental extraction and freshness checks over multiple runs, not just a single pipeline execution.
- **Volume**: demo-scale, ~1k-10k transactions/day — enough for visually meaningful charts without needing to performance-tune the stack; not a load test.
- **Anomalies**: a small, configurable percentage of records are deliberately broken (orphan Bank/Partner records, an occasional missing SFTP file, duplicate Transaction IDs) so the dbt tests, freshness checks, and critical/warning alerting from the observability design (ADR-0008) actually get exercised and proven to fire, rather than existing unexercised in config.
- **Where it runs**: its own `mock_data_producer` Airflow DAG, scheduled ahead of the real extraction DAG each day — reuses the orchestrator already in the stack instead of a second scheduling mechanism, and is trivially disabled (pause the DAG) once real Bank/Partner access exists.
- **Reset behavior**: append-only by default (realistic, and keeps exercising incremental logic honestly), plus a separate `reset_mock_data` DAG/script that wipes the mock Postgres DB, SFTP directory, Kafka topic, lake zones, and warehouse, then reseeds a fresh N-day backfill — for demo resets or a clean dev-iteration slate.

- **Catalog size**: a small fixed set of ~3-5 mock Banks and ~5-10 mock Partners, each with a stable profile (base authorization rate, Decline Reason mix, and Fee Schedule) held consistent across simulated days — enough distinct entities for the partner/bank comparison charts to look meaningful without a large reference dataset to design.

**Schema fidelity is deliberately provisional.** No real Bank/Partner integration spec exists yet, so the mock schema (column names, file layout, formats) is a clean, sensible placeholder rather than modeled on a verified real-world format. Expect the Airbyte connector configs and dbt staging models to need rework once real source formats are known — this is a known, accepted risk of unblocking the POC now rather than waiting on integration specs that don't exist yet.
