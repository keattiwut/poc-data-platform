#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking bank_transactions table has rows..."
COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -tAc \
  "SELECT count(*) FROM bank_transactions;")
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: bank_transactions has no rows (found: ${COUNT:-0})"
  exit 1
fi

echo "Checking partner_transactions has the new bank_id column..."
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -tAc \
  "SELECT bank_id FROM partner_transactions LIMIT 1;" > /dev/null

echo "Checking the orphan scenario exists: at least one transaction_id present in only one of the two tables..."
ORPHAN_COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -tAc "
  SELECT count(*) FROM (
    SELECT transaction_id FROM partner_transactions
    EXCEPT
    SELECT transaction_id FROM bank_transactions
  ) partner_only
  UNION ALL
  SELECT count(*) FROM (
    SELECT transaction_id FROM bank_transactions
    EXCEPT
    SELECT transaction_id FROM partner_transactions
  ) bank_only;
")
TOTAL_ORPHANS=$(echo "$ORPHAN_COUNT" | awk '{sum += $1} END {print sum}')
if [ "${TOTAL_ORPHANS:-0}" -lt 1 ]; then
  echo "FAIL: no orphan transactions found (every transaction_id appears in both tables) - the orphan scenario the full outer join must handle is not being exercised"
  exit 1
fi

echo "PASS: bank_transactions has ${COUNT} rows, partner_transactions has bank_id, ${TOTAL_ORPHANS} orphan transaction(s) exist across both tables"
