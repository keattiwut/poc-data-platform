#!/usr/bin/env bash
set -euo pipefail

echo "=== Rendering fresh .env from Vault ==="
./scripts/render-env-from-vault.sh
set -a; source .env; set +a

echo "=== Seeding mock Partner + Bank transactions (all four channels) ==="
# NOTE (see .superpowers/sdd/task-1-report.md): .env's POSTGRES_HOST /
# SFTP_HOST:PORT / KAFKA_BOOTSTRAP_SERVERS are Docker Compose in-network
# addresses, resolvable only *inside* the Docker network. This script runs on
# the host, so we override them to the host-mapped addresses for this one
# invocation only; .env itself is left untouched so in-network consumers (the
# dlt extraction tasks on the Airflow scheduler) still get the service names.
POSTGRES_HOST=localhost SFTP_HOST=localhost SFTP_PORT=12222 \
  KAFKA_BOOTSTRAP_SERVERS=localhost:9094 \
  python3 mock/generate_transactions.py
./scripts/verify-mock-generator.sh
./scripts/verify-bank-transactions-generated.sh
./scripts/verify-sftp-kafka-generated.sh

echo "=== Extracting all four source channels via dlt -> MinIO bronze (ADR-0024) ==="
# Runs inside the airflow-scheduler container - the same environment (deps +
# in-network endpoints) the daily_pipeline DAG tasks use. MSYS_NO_PATHCONV
# stops Git Bash mangling the in-container /opt/... path into a Windows
# path; harmless no-op elsewhere.
for channel in partner_db bank_db sftp kafka; do
  MSYS_NO_PATHCONV=1 docker compose exec -T airflow-scheduler \
    python /opt/airflow/scripts/extract-to-bronze.py "$channel"
done
./scripts/verify-dlt-bronze.sh

echo "=== Promoting bronze -> silver (Partner + Bank) ==="
python3 scripts/promote-bronze-to-silver.py partner_transactions
python3 scripts/promote-bronze-to-silver.py bank_transactions
./scripts/verify-silver-promotion.sh

echo "=== Running dbt seed + models ==="
(cd dbt/payment_gateway && DBT_PROFILES_DIR=. dbt seed)
(cd dbt/payment_gateway && DBT_PROFILES_DIR=. dbt run)
./scripts/verify-stg-partner-transactions.sh
./scripts/verify-stg-bank-transactions.sh
./scripts/verify-fct-transactions.sh

echo "=== Verifying Superset charts ==="
./scripts/verify-superset-chart.sh

echo ""
echo "=== BANK RECONCILIATION COMPLETE: generator (partner+bank, 4 channels) -> dlt (postgres+sftp+kafka) -> lake -> dbt (reconciliation + fees) -> ClickHouse -> Superset (4 charts) ==="
