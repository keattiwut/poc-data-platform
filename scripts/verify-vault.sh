#!/usr/bin/env bash
set -euo pipefail

echo "Checking Vault is up and unsealed..."
STATUS=$(curl -sf http://localhost:8200/v1/sys/health || echo "UNREACHABLE")
if [ "$STATUS" = "UNREACHABLE" ]; then
  echo "FAIL: Vault is not reachable at http://localhost:8200"
  exit 1
fi

echo "Checking secret/postgres exists in Vault..."
curl -sf -H "X-Vault-Token: poc-dev-root-token" \
  http://localhost:8200/v1/secret/data/postgres > /dev/null

echo "PASS: Vault is up and secret/postgres is populated"
