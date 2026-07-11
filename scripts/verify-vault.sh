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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/../vault/.vault-keys.json"

echo "Checking Vault is reachable..."
SEAL_STATUS=$(curl --cacert "${VAULT_CACERT}" -sf "${VAULT_ADDR}/v1/sys/seal-status" || echo "UNREACHABLE")
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
curl --cacert "${VAULT_CACERT}" -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/secret/data/postgres" > /dev/null

echo "PASS: Vault is up, unsealed, and secret/postgres is populated"
