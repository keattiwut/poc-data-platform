#!/usr/bin/env bash
set -euo pipefail

# Git Bash ships a Schannel-built curl: a private CA has no revocation
# endpoint, so revocation checking must be turned off there for --cacert to
# verify (no-op on OpenSSL-built curls, which skip this branch).
if command curl --version | grep -q Schannel; then
  curl() { command curl --ssl-no-revoke "$@"; }
fi
set -a; source .env; set +a

echo "Checking fct_transactions_current reconciliation: rows exist, no duplicate transaction_ids, both partner-only and bank-only rows are handled, fees are computed for captured transactions..."
CH_NETRC=$(mktemp)
trap 'rm -f "$CH_NETRC"' EXIT
chmod 600 "$CH_NETRC"
printf 'machine localhost login %s password %s\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" > "$CH_NETRC"

RESULT=$(curl -sf --netrc-file "$CH_NETRC" --cacert tls/ca.crt "https://localhost:8124/" --data-binary @- <<'EOSQL'
SELECT
    count(*) AS total_rows,
    count(*) - count(DISTINCT transaction_id) AS duplicate_transaction_ids,
    countIf(initiated_at IS NULL AND bank_id IS NOT NULL) AS bank_only_rows,
    countIf(initiated_at IS NOT NULL AND bank_state IS NULL) AS partner_only_rows,
    countIf((captured_at IS NOT NULL OR bank_captured_at IS NOT NULL) AND fee_amount_cents IS NULL) AS captured_without_fee,
    countIf(fee_amount_cents IS NOT NULL) AS rows_with_fee
FROM fct_transactions_current
FORMAT TabSeparated
EOSQL
)

TOTAL=$(echo "$RESULT" | cut -f1)
DUPES=$(echo "$RESULT" | cut -f2)
BANK_ONLY=$(echo "$RESULT" | cut -f3)
PARTNER_ONLY=$(echo "$RESULT" | cut -f4)
CAPTURED_WITHOUT_FEE=$(echo "$RESULT" | cut -f5)
WITH_FEE=$(echo "$RESULT" | cut -f6)

if [ "${TOTAL:-0}" -lt 1 ]; then
  echo "FAIL: fct_transactions_current has no rows"
  exit 1
fi
if [ "${DUPES:-1}" -ne 0 ]; then
  echo "FAIL: found ${DUPES} duplicate transaction_id(s) - dedup view is broken"
  exit 1
fi
if [ "${BANK_ONLY:-0}" -lt 1 ]; then
  echo "FAIL: expected at least one Bank-only orphan row (initiated_at NULL, bank_id set) - full outer join is not preserving Bank-only transactions"
  exit 1
fi
if [ "${PARTNER_ONLY:-0}" -lt 1 ]; then
  echo "FAIL: expected at least one Partner-only orphan row (initiated_at set, bank_state NULL) - full outer join is not preserving Partner-only transactions"
  exit 1
fi
if [ "${CAPTURED_WITHOUT_FEE:-1}" -ne 0 ]; then
  echo "FAIL: found ${CAPTURED_WITHOUT_FEE} transaction(s) captured on either side with no fee computed - fee-at-capture logic is broken"
  exit 1
fi
if [ "${WITH_FEE:-0}" -lt 1 ]; then
  echo "FAIL: no rows have a computed fee at all - fee schedule join is not matching anything"
  exit 1
fi

echo "PASS: fct_transactions_current has ${TOTAL} rows (0 duplicates), ${PARTNER_ONLY} Partner-only + ${BANK_ONLY} Bank-only orphan rows correctly reconciled, ${WITH_FEE} rows with a computed fee"
