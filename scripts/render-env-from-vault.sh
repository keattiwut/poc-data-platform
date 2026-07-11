#!/usr/bin/env bash
set -euo pipefail

# Git Bash ships a Schannel-built curl: a private CA has no revocation
# endpoint, so revocation checking must be turned off there for --cacert to
# verify (no-op on OpenSSL-built curls, which skip this branch).
if command curl --version | grep -q Schannel; then
  curl() { command curl --ssl-no-revoke "$@"; }
fi

VAULT_ADDR="${VAULT_ADDR:-https://localhost:8200}"
# Vault serves TLS from the local internal CA (Issue 09 / ADR-0017);
# clients verify against it rather than passing -k.
VAULT_CACERT="${VAULT_CACERT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tls/ca.crt}"

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
curl --cacert "${VAULT_CACERT}" -sf "${VAULT_ADDR}/v1/sys/health" > /dev/null \
  || { echo "ERROR: Vault unreachable or sealed at ${VAULT_ADDR} — run ./vault/init-unseal.sh" >&2; exit 1; }

get_field() {
  local path="$1"
  local field="$2"
  local value
  value=$(curl --cacert "${VAULT_CACERT}" -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
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
SFTP_HOST=$(get_field sftp host)
SFTP_PORT=$(get_field sftp port)
SFTP_USER=$(get_field sftp user)
SFTP_PASSWORD=$(get_field sftp password)
KAFKA_BOOTSTRAP_SERVERS=$(get_field kafka bootstrap_servers)
GRAFANA_ADMIN_USER=$(get_field grafana admin_user)
GRAFANA_ADMIN_PASSWORD=$(get_field grafana admin_password)
MINIO_EXTRACTION_USER=$(get_field minio-services extraction_user)
MINIO_EXTRACTION_PASSWORD=$(get_field minio-services extraction_password)
MINIO_PROMOTION_USER=$(get_field minio-services promotion_user)
MINIO_PROMOTION_PASSWORD=$(get_field minio-services promotion_password)
MINIO_WAREHOUSE_USER=$(get_field minio-services warehouse_user)
MINIO_WAREHOUSE_PASSWORD=$(get_field minio-services warehouse_password)
MINIO_KMS_SECRET_KEY=$(get_field encryption minio_kms_secret_key)
CLICKHOUSE_DISK_KEY_HEX=$(get_field encryption clickhouse_disk_key_hex)

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
  echo "SFTP_HOST=${SFTP_HOST}"
  echo "SFTP_PORT=${SFTP_PORT}"
  echo "SFTP_USER=${SFTP_USER}"
  echo "SFTP_PASSWORD=${SFTP_PASSWORD}"
  echo "KAFKA_BOOTSTRAP_SERVERS=${KAFKA_BOOTSTRAP_SERVERS}"
  echo "GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}"
  echo "GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}"
  echo "MINIO_EXTRACTION_USER=${MINIO_EXTRACTION_USER}"
  echo "MINIO_EXTRACTION_PASSWORD=${MINIO_EXTRACTION_PASSWORD}"
  echo "MINIO_PROMOTION_USER=${MINIO_PROMOTION_USER}"
  echo "MINIO_PROMOTION_PASSWORD=${MINIO_PROMOTION_PASSWORD}"
  echo "MINIO_WAREHOUSE_USER=${MINIO_WAREHOUSE_USER}"
  echo "MINIO_WAREHOUSE_PASSWORD=${MINIO_WAREHOUSE_PASSWORD}"
  echo "MINIO_KMS_SECRET_KEY=${MINIO_KMS_SECRET_KEY}"
  echo "CLICKHOUSE_DISK_KEY_HEX=${CLICKHOUSE_DISK_KEY_HEX}"
} > .env

echo "Rendered .env from Vault secrets."
