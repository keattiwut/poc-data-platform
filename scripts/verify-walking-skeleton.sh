#!/usr/bin/env bash
set -euo pipefail

echo "=== Rendering fresh .env from Vault ==="
./scripts/render-env-from-vault.sh
set -a; source .env; set +a

echo "=== Seeding mock Partner + Bank transactions ==="
# NOTE (see .superpowers/sdd/task-1-report.md): .env's POSTGRES_HOST is
# "postgres" - the Docker Compose service name, resolvable only *inside* the
# Docker network. This script runs on the host, so we override POSTGRES_HOST
# to the mapped host port for this one invocation only; .env itself is left
# untouched so in-network consumers (Airbyte's source config, etc.) still
# get "postgres".
POSTGRES_HOST=localhost python3 mock/generate_transactions.py
./scripts/verify-mock-generator.sh
./scripts/verify-bank-transactions-generated.sh

echo "=== Syncing Airbyte Postgres -> MinIO bronze (Partner + Bank) ==="
./scripts/configure-airbyte-partner-source.sh
./scripts/verify-airbyte-bronze-sync.sh
./scripts/configure-airbyte-bank-source.sh
./scripts/verify-airbyte-bank-bronze-sync.sh

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
echo "=== BANK RECONCILIATION COMPLETE: generator (partner+bank) -> Airbyte (2 sources) -> lake -> dbt (reconciliation + fees) -> ClickHouse -> Superset (4 charts) ==="
