#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"

# Root token comes from vault/.vault-keys.json, written by vault/init-unseal.sh
# on first initialization (git-ignored). Overridable via VAULT_TOKEN env var.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/.vault-keys.json"
if [ -z "${VAULT_TOKEN:-}" ]; then
  if [ ! -f "${KEYS_FILE}" ]; then
    echo "ERROR: ${KEYS_FILE} not found — run ./vault/init-unseal.sh first" >&2
    exit 1
  fi
  VAULT_TOKEN=$(jq -r .root_token "${KEYS_FILE}")
fi

put_secret() {
  local path="$1"
  shift
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${path}")
  if [ "$http_code" = "200" ]; then
    echo "secret/${path} already exists, skipping (idempotent)"
    return 0
  elif [ "$http_code" != "404" ]; then
    echo "ERROR: unexpected response checking secret/${path} (HTTP ${http_code}) — refusing to write, could indicate an auth or connectivity problem" >&2
    exit 1
  fi
  curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"data\": {$*}}" \
    "${VAULT_ADDR}/v1/secret/data/${path}" > /dev/null
  echo "Seeded secret/${path}"
}

random_password() {
  openssl rand -hex 16
}

put_secret "postgres" \
  "\"user\": \"pipeline_admin\", \"password\": \"$(random_password)\", \"host\": \"postgres\", \"port\": \"5432\", \"db\": \"pipeline\""

put_secret "minio" \
  "\"root_user\": \"pipeline_minio_admin\", \"root_password\": \"$(random_password)\""

put_secret "airflow" \
  "\"fernet_key\": \"$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' 2>/dev/null || openssl rand -base64 32 | tr '+/' '-_')\", \"admin_user\": \"admin\", \"admin_password\": \"$(random_password)\""

put_secret "clickhouse" \
  "\"user\": \"pipeline_ch_admin\", \"password\": \"$(random_password)\""

put_secret "superset" \
  "\"secret_key\": \"$(openssl rand -base64 42)\", \"admin_user\": \"admin\", \"admin_password\": \"$(random_password)\""

echo "Vault secret seeding complete."
