# Runbook: extraction task failed

**Alert**: Critical (Airflow `daily_pipeline.extract_*` failure callback, or
`MinIOUnreachable`). Successor to the Airbyte-era "sync failed" runbook -
extraction is dlt running inside the scheduler since ADR-0024.

## Diagnose

1. Which channel? The alert names the task: `extract_partner_db`,
   `extract_bank_db`, `extract_sftp`, or `extract_kafka`.
2. Read its log (Airflow UI → daily_pipeline → run → task → log). dlt
   errors name the failing step (extract/normalize/load).
3. Most likely per channel:
   - **partner_db / bank_db**: mock Postgres down or credentials stale →
     `docker compose ps postgres`, then re-render credentials:
     `./scripts/render-env-from-vault.sh && docker compose up -d`.
   - **sftp**: SFTP server down (`docker compose ps sftp`) or the `.env`
     SFTP values are the host-side ones (in-network is `sftp:22`).
   - **kafka**: broker down (`docker compose ps kafka`), or offsets state
     desynced after a manual topic wipe - a reset that deletes topics MUST
     also wipe dlt state (`reset_mock_data` does; see
     `scripts/reset-mock-data.py`).
   - **All four failing**: MinIO (the destination) is down →
     `docker compose up -d minio`, verify with
     `./scripts/verify-postgres-minio.sh`.

## Fix

4. Bring the failed dependency up, then clear/re-run the failed task in the
   Airflow UI (or re-trigger `daily_pipeline`). Extraction is
   replace/append + silver dedup, so re-runs never duplicate data.
5. Verify bronze landed: `./scripts/verify-dlt-bronze.sh`; for Kafka
   specifically: `./scripts/verify-kafka-drain.sh`.

## Data-loss expectations

Nothing is lost by a failed run: Postgres keeps its rows, unread Kafka
messages wait on the broker, and SFTP files stay until read. The next
successful run picks everything up.
