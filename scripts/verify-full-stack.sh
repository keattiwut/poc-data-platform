#!/usr/bin/env bash
set -euo pipefail

# Vault runs in server mode with the `file` storage backend (ADR-0023):
# secrets survive restarts, but Vault always comes back *sealed*. Bring it up,
# wait for it to respond, init/unseal it (idempotent — first boot initializes
# and saves the key/token to vault/.vault-keys.json, later boots just unseal),
# then seed it before rendering .env. A sealed/uninitialized Vault returns
# non-200 on /v1/sys/health, so the wait loop remaps those states to 200 —
# it only asserts "Vault is responding", init-unseal handles the rest.
echo "=== Starting Vault ==="
docker compose up -d vault

echo "=== Waiting for Vault to respond ==="
VAULT_HEALTH_URL="http://localhost:8200/v1/sys/health?sealedcode=200&uninitcode=200"
for i in $(seq 1 30); do
  if curl -sf "${VAULT_HEALTH_URL}" > /dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf "${VAULT_HEALTH_URL}" > /dev/null \
  || { echo "FAIL: Vault did not come up in time" >&2; exit 1; }

echo "=== Initializing/unsealing Vault (idempotent) ==="
./vault/init-unseal.sh

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
./scripts/verify-sftp-kafka-infra.sh
./scripts/verify-dbt.sh
./scripts/check-no-committed-secrets.sh

echo ""
echo "=== ALL SERVICES HEALTHY - INFRA BOOTSTRAP COMPLETE ==="
