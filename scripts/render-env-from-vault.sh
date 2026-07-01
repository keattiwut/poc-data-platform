#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="http://localhost:8200"
VAULT_TOKEN="poc-dev-root-token"

get_field() {
  local path="$1"
  local field="$2"
  curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${path}" \
    | jq -r ".data.data.${field}"
}

{
  echo "POSTGRES_USER=$(get_field postgres user)"
  echo "POSTGRES_PASSWORD=$(get_field postgres password)"
  echo "POSTGRES_HOST=$(get_field postgres host)"
  echo "POSTGRES_PORT=$(get_field postgres port)"
  echo "POSTGRES_DB=$(get_field postgres db)"
  echo "MINIO_ROOT_USER=$(get_field minio root_user)"
  echo "MINIO_ROOT_PASSWORD=$(get_field minio root_password)"
  echo "AIRFLOW_FERNET_KEY=$(get_field airflow fernet_key)"
  echo "AIRFLOW_ADMIN_USER=$(get_field airflow admin_user)"
  echo "AIRFLOW_ADMIN_PASSWORD=$(get_field airflow admin_password)"
} > .env

echo "Rendered .env from Vault secrets."
