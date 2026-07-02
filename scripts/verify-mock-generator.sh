#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking partner_transactions table has rows..."
COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -tAc \
  "SELECT count(*) FROM partner_transactions;")
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: partner_transactions has no rows (found: ${COUNT:-0})"
  exit 1
fi

echo "Checking every row has a non-null transaction_id and state..."
NULLS=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -tAc \
  "SELECT count(*) FROM partner_transactions WHERE transaction_id IS NULL OR state IS NULL;")
if [ "${NULLS:-1}" -ne 0 ]; then
  echo "FAIL: found rows with null transaction_id or state"
  exit 1
fi

echo "PASS: partner_transactions has ${COUNT} rows, all with valid transaction_id/state"
