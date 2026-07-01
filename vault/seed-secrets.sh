#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="http://localhost:8200"
VAULT_TOKEN="poc-dev-root-token"

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
  "\"fernet_key\": \"$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' 2>/dev/null || openssl rand -base64 32)\", \"admin_user\": \"admin\", \"admin_password\": \"$(random_password)\""

put_secret "clickhouse" \
  "\"user\": \"pipeline_ch_admin\", \"password\": \"$(random_password)\""

echo "Vault secret seeding complete."
