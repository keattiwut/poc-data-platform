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
  http_code=$(curl --cacert "${VAULT_CACERT}" -s -o /dev/null -w "%{http_code}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/${path}")
  if [ "$http_code" = "200" ]; then
    echo "secret/${path} already exists, skipping (idempotent)"
    return 0
  elif [ "$http_code" != "404" ]; then
    echo "ERROR: unexpected response checking secret/${path} (HTTP ${http_code}) — refusing to write, could indicate an auth or connectivity problem" >&2
    exit 1
  fi
  curl --cacert "${VAULT_CACERT}" -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
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

# In-network address, like postgres/kafka above (the container listens on 22;
# 2222 is only the host-side port mapping — host-side scripts override both
# host and port). Issue 04 fix: this was seeded as the inconsistent
# host="sftp"/port="2222" hybrid before the first in-network consumer (the
# dlt SFTP extraction task) existed to notice.
put_secret "sftp" \
  "\"host\": \"sftp\", \"port\": \"22\", \"user\": \"mockuser\", \"password\": \"$(random_password)\""

put_secret "kafka" \
  "\"bootstrap_servers\": \"kafka:9092\""

put_secret "grafana" \
  "\"admin_user\": \"admin\", \"admin_password\": \"$(random_password)\""

# Issue 09 (ADR-0017 / review finding 7): per-service least-privilege MinIO
# users - root stays admin-only. Created in MinIO by
# docker/minio/setup-service-users.sh at bring-up.
put_secret "minio-services" \
  "\"extraction_user\": \"svc_extraction\", \"extraction_password\": \"$(random_password)\", \"promotion_user\": \"svc_promotion\", \"promotion_password\": \"$(random_password)\", \"warehouse_user\": \"svc_warehouse\", \"warehouse_password\": \"$(random_password)\""

# Encryption-at-rest keys (ADR-0017): MinIO's built-in single-key KMS
# ("name:base64(32B)") and ClickHouse's encrypted-disk key (hex, 32B).
put_secret "encryption" \
  "\"minio_kms_secret_key\": \"pipeline-sse-key:$(openssl rand -base64 32)\", \"clickhouse_disk_key_hex\": \"$(openssl rand -hex 32)\""

echo "Vault secret seeding complete."
