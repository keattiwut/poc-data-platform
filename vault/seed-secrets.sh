#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="http://localhost:8200"
VAULT_TOKEN="poc-dev-root-token"

put_secret() {
  local path="$1"
  shift
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

echo "Vault secret seeding complete."
