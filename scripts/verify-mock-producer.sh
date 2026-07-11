#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# Verifies the full mock generator (Issue 05 / ADR-0010) end to end, after
# mock_data_producer (backfill) and daily_pipeline (extraction+dbt) have run:
# the warehouse should show the whole catalog (6 partners, 4 banks) with
# backfill-deep history.

BACKFILL_DAYS="${MOCK_BACKFILL_DAYS:-45}"
# The backfill is BACKFILL_DAYS long, but lifecycle timestamps can spill a
# day either way; require at least BACKFILL_DAYS - 1 distinct days.
MIN_DAYS=$((BACKFILL_DAYS - 1))

CH="docker compose exec -T clickhouse clickhouse-client --user ${CLICKHOUSE_USER} --password ${CLICKHOUSE_PASSWORD}"

echo "Checking fct_transactions_current spans the backfill window..."
DAYS=$($CH --query "SELECT uniqExact(toDate(initiated_at)) FROM default.fct_transactions_current WHERE initiated_at IS NOT NULL")
if [ "${DAYS:-0}" -lt "$MIN_DAYS" ]; then
  echo "FAIL: only ${DAYS:-0} distinct day(s) in fct_transactions_current; expected >= ${MIN_DAYS}"
  exit 1
fi
echo "PASS: ${DAYS} distinct days of history (backfill window ${BACKFILL_DAYS})"

echo "Checking the full entity catalog reaches the warehouse..."
PARTNERS=$($CH --query "SELECT uniqExact(partner_id) FROM default.fct_transactions_current")
BANKS=$($CH --query "SELECT uniqExact(bank_id) FROM default.fct_transactions_current")
if [ "${PARTNERS:-0}" -ne 6 ] || [ "${BANKS:-0}" -ne 4 ]; then
  echo "FAIL: expected 6 partners and 4 banks in fct_transactions_current, found ${PARTNERS:-0}/${BANKS:-0}"
  exit 1
fi
echo "PASS: all 6 partners and 4 banks present"

echo "Checking entity profiles are distinct (auth rate spread)..."
SPREAD=$($CH --query "
  SELECT round(max(rate) - min(rate), 3) FROM (
    SELECT partner_id, countIf(state != 'failed' OR bank_state != 'failed') / count() AS rate
    FROM default.fct_transactions_current GROUP BY partner_id
  )")
# Catalog auth rates span 0.80..0.95; demand at least half that spread shows
# through the noise.
if ! python3 -c "import sys; sys.exit(0 if float('${SPREAD:-0}') >= 0.07 else 1)"; then
  echo "FAIL: partner auth-rate spread ${SPREAD:-0} is too small for the catalog's distinct profiles"
  exit 1
fi
echo "PASS: partner auth-rate spread ${SPREAD} - profiles are distinct"

echo "Checking every partner x bank pair has a fee schedule row..."
MISSING=$($CH --query "
  SELECT count() FROM (
    SELECT DISTINCT partner_id, bank_id FROM default.fct_transactions_current
  ) pairs
  LEFT JOIN default.fee_schedule fs USING (partner_id, bank_id)
  WHERE fs.fixed_fee_cents IS NULL OR fs.fixed_fee_cents = 0")
if [ "${MISSING:-1}" -ne 0 ]; then
  echo "FAIL: ${MISSING} partner x bank pair(s) missing from the fee_schedule seed"
  exit 1
fi
echo "PASS: fee schedule covers every observed partner x bank pair"
