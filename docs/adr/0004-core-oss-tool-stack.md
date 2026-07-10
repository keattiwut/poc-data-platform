# Core open-source tool stack

Each layer of the pipeline uses a specific open-source, industry-standard tool rather than custom-building or reaching for a managed/proprietary service:

- **Orchestrator: Apache Airflow** — replaces crontab; owns DAGs, retries, backfills, dependency ordering.
- **Extraction: dlt** (amended 2026-07-10 by [ADR-0024](./0024-dlt-instead-of-airbyte.md); originally Airbyte, see [ADR-0020](./0020-airbyte-via-abctl.md)) — Python-library extraction from database/Excel/CSV/message-queue sources into the lake's bronze zone, running as ordinary Airflow tasks with credentials from the same Vault render as every other service.
- **Transform: dbt** — SQL-first transformation from bronze/silver/gold into warehouse/mart tables, run as Airflow tasks (via Cosmos).
- **Warehouse: ClickHouse** — columnar OLAP database purpose-built for the BI query patterns the marts need to serve.
- **BI: Apache Superset** — fully open-source (Apache-governed, no enterprise-tier feature paywall) dashboarding layer on top of ClickHouse.

Each of these carries real switching cost (a quarter or more to replace), so they're recorded together as the platform's foundational stack. See [0001](./0001-batch-not-streaming.md)-[0003](./0003-parquet-medallion-lake.md) for the related batch/infra/lake-format decisions.
