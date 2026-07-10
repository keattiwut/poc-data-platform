#!/usr/bin/env bash
set -euo pipefail

# Initialize and/or unseal the server-mode Vault (ADR-0023). Idempotent:
#   - uninitialized -> initialize with 1 key share / threshold 1 (HTTP-API
#                      equivalent of `vault operator init -key-shares=1
#                      -key-threshold=1`), save the unseal key + root token
#                      to vault/.vault-keys.json (git-ignored), then unseal
#   - sealed        -> unseal with the saved key
#   - unsealed      -> no-op
# Also ensures the KV v2 secrets engine is mounted at secret/ — dev mode
# auto-mounted it, server mode does not, and every other script here reads
# and writes /v1/secret/data/* paths.

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/.vault-keys.json"

seal_status=$(curl -sf "${VAULT_ADDR}/v1/sys/seal-status") \
  || { echo "ERROR: Vault unreachable at ${VAULT_ADDR}" >&2; exit 1; }
initialized=$(echo "${seal_status}" | jq -r .initialized)
sealed=$(echo "${seal_status}" | jq -r .sealed)

if [ "${initialized}" != "true" ]; then
  echo "Vault is uninitialized — initializing (1 key share, threshold 1)..."
  init_response=$(curl -sf -X PUT \
    -d '{"secret_shares": 1, "secret_threshold": 1}' \
    "${VAULT_ADDR}/v1/sys/init")
  umask 077
  echo "${init_response}" | jq . > "${KEYS_FILE}"
  echo "Saved unseal key + root token to ${KEYS_FILE} (git-ignored — never commit it; losing it means losing access to Vault's storage)"
  sealed="true"
fi

if [ "${sealed}" = "true" ]; then
  if [ ! -f "${KEYS_FILE}" ]; then
    echo "ERROR: Vault is sealed but ${KEYS_FILE} is missing — cannot unseal" >&2
    exit 1
  fi
  unseal_key=$(jq -r '.keys_base64[0]' "${KEYS_FILE}")
  if [ -z "${unseal_key}" ] || [ "${unseal_key}" = "null" ]; then
    echo "ERROR: no unseal key found in ${KEYS_FILE}" >&2
    exit 1
  fi
  unseal_response=$(curl -sf -X PUT \
    -d "{\"key\": \"${unseal_key}\"}" \
    "${VAULT_ADDR}/v1/sys/unseal")
  if [ "$(echo "${unseal_response}" | jq -r .sealed)" != "false" ]; then
    echo "ERROR: unseal request did not leave Vault unsealed" >&2
    exit 1
  fi
  echo "Vault unsealed."
else
  echo "Vault already initialized and unsealed."
fi

# Ensure KV v2 is mounted at secret/ (idempotent). Dev mode did this
# automatically; server mode starts with no secrets engines mounted.
if [ -z "${VAULT_TOKEN:-}" ]; then
  if [ ! -f "${KEYS_FILE}" ]; then
    echo "ERROR: ${KEYS_FILE} is missing and VAULT_TOKEN is not set — cannot verify the secret/ mount" >&2
    exit 1
  fi
  VAULT_TOKEN=$(jq -r .root_token "${KEYS_FILE}")
fi
if ! curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/mounts" \
    | jq -e '."secret/"' > /dev/null; then
  curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -X POST \
    -d '{"type": "kv", "options": {"version": "2"}}' \
    "${VAULT_ADDR}/v1/sys/mounts/secret" > /dev/null
  echo "Mounted KV v2 secrets engine at secret/"
fi

echo "Vault init/unseal complete."
