#!/usr/bin/env bash
set -euo pipefail

echo "=== Rendering fresh .env from Vault ==="
./scripts/render-env-from-vault.sh
set -a; source .env; set +a

echo "=== Seeding mock Partner transactions ==="
# NOTE (see .superpowers/sdd/task-1-report.md): .env's POSTGRES_HOST is
# "postgres" - the Docker Compose service name, resolvable only *inside* the
# Docker network. This script runs on the host, so we override POSTGRES_HOST
# to the mapped host port for this one invocation only; .env itself is left
# untouched so in-network consumers (Airbyte's source config, etc.) still
# get "postgres".
POSTGRES_HOST=localhost python3 mock/generate_partner_transactions.py
./scripts/verify-mock-generator.sh

echo "=== Syncing Airbyte Postgres -> MinIO bronze ==="
./scripts/configure-airbyte-partner-source.sh
./scripts/verify-airbyte-bronze-sync.sh

echo "=== Promoting bronze -> silver ==="
python3 scripts/promote-bronze-to-silver.py
./scripts/verify-silver-promotion.sh

echo "=== Running dbt models ==="
(cd dbt/payment_gateway && DBT_PROFILES_DIR=. dbt run)
./scripts/verify-stg-partner-transactions.sh
./scripts/verify-fct-transactions.sh

echo "=== Verifying Superset chart ==="
./scripts/verify-superset-chart.sh

echo ""
echo "=== WALKING SKELETON COMPLETE: generator -> Airbyte -> lake -> dbt -> ClickHouse -> Superset ==="
