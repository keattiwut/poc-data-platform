#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking fct_transactions_current has rows, Bank-side columns null, no duplicate transaction_ids..."
# Credentials go through --netrc-file, not embedded in the URL - see
# scripts/verify-clickhouse.sh for why (visible in `ps aux` otherwise).
CH_NETRC=$(mktemp)
trap 'rm -f "$CH_NETRC"' EXIT
chmod 600 "$CH_NETRC"
printf 'machine localhost login %s password %s\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" > "$CH_NETRC"

RESULT=$(curl -sf --netrc-file "$CH_NETRC" "http://localhost:8124/" --data-binary @- <<'EOSQL'
SELECT
    count(*) AS total_rows,
    countIf(bank_id IS NOT NULL) AS non_null_bank_rows,
    count(*) - count(DISTINCT transaction_id) AS duplicate_transaction_ids
FROM fct_transactions_current
FORMAT TabSeparated
EOSQL
)

TOTAL=$(echo "$RESULT" | cut -f1)
BANK_NON_NULL=$(echo "$RESULT" | cut -f2)
DUPES=$(echo "$RESULT" | cut -f3)

if [ "${TOTAL:-0}" -lt 1 ]; then
  echo "FAIL: fct_transactions_current has no rows"
  exit 1
fi
if [ "${BANK_NON_NULL:-1}" -ne 0 ]; then
  echo "FAIL: expected all bank_id values to be NULL in this slice, found ${BANK_NON_NULL} non-null"
  exit 1
fi
if [ "${DUPES:-1}" -ne 0 ]; then
  echo "FAIL: found ${DUPES} duplicate transaction_id(s) in fct_transactions_current - dedup view is broken"
  exit 1
fi

echo "PASS: fct_transactions_current has ${TOTAL} rows, no bank-side data, no duplicates"
