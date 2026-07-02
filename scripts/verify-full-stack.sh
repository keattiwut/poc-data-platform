#!/usr/bin/env bash
set -euo pipefail

echo "=== Rendering fresh .env from Vault ==="
./scripts/render-env-from-vault.sh

# .env has plain KEY=VALUE lines (no `export`), so a plain `source .env` only
# sets shell variables in this process — it does not mark them for export, so
# child processes (like the `dbt` invocation inside verify-dbt.sh, which reads
# CLICKHOUSE_USER/CLICKHOUSE_PASSWORD via profiles.yml's env_var()) would not
# inherit them. Use `set -a` so every variable sourced from .env is exported.
# Same pattern used in scripts/verify-postgres-minio.sh and
# scripts/verify-clickhouse.sh.
set -a
source .env
set +a

echo "=== Bringing up full Docker Compose stack ==="
docker compose up -d
sleep 30

echo "=== Running per-service verification ==="
./scripts/verify-vault.sh
./scripts/verify-postgres-minio.sh
./scripts/verify-airflow.sh
./scripts/verify-clickhouse.sh
./scripts/verify-superset.sh
./scripts/verify-airbyte.sh
./scripts/verify-dbt.sh
./scripts/check-no-committed-secrets.sh

echo ""
echo "=== ALL SERVICES HEALTHY - INFRA BOOTSTRAP COMPLETE ==="
