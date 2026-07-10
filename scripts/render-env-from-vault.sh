#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"

# Root token comes from vault/.vault-keys.json, written by vault/init-unseal.sh
# on first initialization (git-ignored). Overridable via VAULT_TOKEN env var.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/../vault/.vault-keys.json"
if [ -z "${VAULT_TOKEN:-}" ]; then
  if [ ! -f "${KEYS_FILE}" ]; then
    echo "ERROR: ${KEYS_FILE} not found — run ./vault/init-unseal.sh first" >&2
    exit 1
  fi
  VAULT_TOKEN=$(jq -r .root_token "${KEYS_FILE}")
fi

# Fail loudly up front if Vault isn't reachable or still sealed, rather than
# letting every get_field call below fail silently and render a .env full of
# empty values. /v1/sys/health returns non-200 while sealed/uninitialized.
curl -sf "${VAULT_ADDR}/v1/sys/health" > /dev/null \
  || { echo "ERROR: Vault unreachable or sealed at ${VAULT_ADDR} — run ./vault/init-unseal.sh" >&2; exit 1; }

get_field() {
  local path="$1"
  local field="$2"
  local value
  value=$(curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${path}" \
    | jq -r ".data.data.${field}")
  if [ -z "${value}" ] || [ "${value}" = "null" ]; then
    echo "ERROR: Vault field '${field}' at secret/${path} is empty or missing" >&2
    exit 1
  fi
  echo "${value}"
}

# Capture each field into a plain variable assignment (not `local`) before
# echoing it, so a failing get_field call aborts the script under `set -e`.
# (A `$(get_field ...)` failure nested inside an `echo "KEY=$(...)"` argument
# would otherwise be swallowed — the outer `echo` still succeeds, `set -e`
# never sees a non-zero status, and the script would print "Rendered .env"
# and exit 0 with an empty value silently written to .env.)
POSTGRES_USER=$(get_field postgres user)
POSTGRES_PASSWORD=$(get_field postgres password)
POSTGRES_HOST=$(get_field postgres host)
POSTGRES_PORT=$(get_field postgres port)
POSTGRES_DB=$(get_field postgres db)
MINIO_ROOT_USER=$(get_field minio root_user)
MINIO_ROOT_PASSWORD=$(get_field minio root_password)
AIRFLOW_FERNET_KEY=$(get_field airflow fernet_key)
AIRFLOW_ADMIN_USER=$(get_field airflow admin_user)
AIRFLOW_ADMIN_PASSWORD=$(get_field airflow admin_password)
CLICKHOUSE_USER=$(get_field clickhouse user)
CLICKHOUSE_PASSWORD=$(get_field clickhouse password)
SUPERSET_SECRET_KEY=$(get_field superset secret_key)
SUPERSET_ADMIN_USER=$(get_field superset admin_user)
SUPERSET_ADMIN_PASSWORD=$(get_field superset admin_password)

{
  echo "POSTGRES_USER=${POSTGRES_USER}"
  echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
  echo "POSTGRES_HOST=${POSTGRES_HOST}"
  echo "POSTGRES_PORT=${POSTGRES_PORT}"
  echo "POSTGRES_DB=${POSTGRES_DB}"
  echo "MINIO_ROOT_USER=${MINIO_ROOT_USER}"
  echo "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
  echo "AIRFLOW_FERNET_KEY=${AIRFLOW_FERNET_KEY}"
  echo "AIRFLOW_ADMIN_USER=${AIRFLOW_ADMIN_USER}"
  echo "AIRFLOW_ADMIN_PASSWORD=${AIRFLOW_ADMIN_PASSWORD}"
  echo "CLICKHOUSE_USER=${CLICKHOUSE_USER}"
  echo "CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}"
  echo "SUPERSET_SECRET_KEY=${SUPERSET_SECRET_KEY}"
  echo "SUPERSET_ADMIN_USER=${SUPERSET_ADMIN_USER}"
  echo "SUPERSET_ADMIN_PASSWORD=${SUPERSET_ADMIN_PASSWORD}"
} > .env

echo "Rendered .env from Vault secrets."
