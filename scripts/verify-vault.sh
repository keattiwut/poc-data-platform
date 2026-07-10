#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/../vault/.vault-keys.json"

echo "Checking Vault is reachable..."
SEAL_STATUS=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status" || echo "UNREACHABLE")
if [ "$SEAL_STATUS" = "UNREACHABLE" ]; then
  echo "FAIL: Vault is not reachable at ${VAULT_ADDR}"
  exit 1
fi

echo "Checking Vault is initialized and unsealed..."
if [ "$(echo "$SEAL_STATUS" | jq -r .initialized)" != "true" ] \
  || [ "$(echo "$SEAL_STATUS" | jq -r .sealed)" != "false" ]; then
  echo "FAIL: Vault is uninitialized or sealed — run ./vault/init-unseal.sh"
  exit 1
fi

# Root token comes from vault/.vault-keys.json, written by vault/init-unseal.sh
# on first initialization (git-ignored). Overridable via VAULT_TOKEN env var.
if [ -z "${VAULT_TOKEN:-}" ]; then
  if [ ! -f "${KEYS_FILE}" ]; then
    echo "FAIL: ${KEYS_FILE} not found — run ./vault/init-unseal.sh first"
    exit 1
  fi
  VAULT_TOKEN=$(jq -r .root_token "${KEYS_FILE}")
fi

echo "Checking secret/postgres exists in Vault..."
curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/secret/data/postgres" > /dev/null

echo "PASS: Vault is up, unsealed, and secret/postgres is populated"
