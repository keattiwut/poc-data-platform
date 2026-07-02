#!/usr/bin/env bash
set -euo pipefail

# Vault runs in dev mode (in-memory storage) and must be up and seeded before
# anything can be rendered from it. Bring it up (and wait for its healthcheck)
# and seed it here, before rendering .env, rather than assuming ambient state
# from a previous run — on a clean machine, or after `docker compose down`,
# Vault would otherwise not exist yet / would have lost all its secrets.
echo "=== Starting Vault ==="
docker compose up -d vault

echo "=== Waiting for Vault to become healthy ==="
for i in $(seq 1 30); do
  if curl -sf http://localhost:8200/v1/sys/health > /dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf http://localhost:8200/v1/sys/health > /dev/null \
  || { echo "FAIL: Vault did not become healthy in time" >&2; exit 1; }

echo "=== Seeding Vault secrets (idempotent, skips secrets that already exist) ==="
./vault/seed-secrets.sh

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
