#!/usr/bin/env bash
set -euo pipefail

# Standalone repro for the ClickHouse s3()-view join bug (ADR-0022, Issue 12).
#
# On clickhouse-server 24.10.4, joining the s3()-backed staging views
# stg_partner_transactions / stg_bank_transactions directly (FULL OUTER JOIN,
# CTE, parenthesized subquery, UNION ALL - all reproduced it) silently
# returned NULL for an unpredictable subset of the joined-in columns, even for
# rows that plainly matched on both sides. `bank_id`, `decline_reason` and
# `bank_decline_reason` were the most consistently affected, but which columns
# broke varied with total column count. See the header comments of
# dbt/payment_gateway/models/intermediate/int_reconciled_transactions.sql for
# the full write-up, and int_partner_transactions / int_bank_transactions for
# the snapshot-table workaround this script exists to retire.
#
# What this script does:
#   1. Reads each staging view ALONE (single-view scans are the known-good
#      path - the int_* snapshot models rely on exactly that) to establish,
#      for the transaction_ids present on BOTH sides, how many rows carry a
#      non-NULL bank_id / decline_reason / bank_decline_reason.
#   2. Runs the suspect FULL OUTER JOIN directly against the two s3() views,
#      mirroring int_reconciled_transactions' column complement.
#   3. Compares the join's matched-row non-NULL counts against the baseline.
#      Any shortfall means the join silently NULLed values -> exit non-zero,
#      loudly.
#
# PASS here is the precondition for deleting the int_partner_transactions /
# int_bank_transactions workaround models. FAIL means the pinned ClickHouse
# version still has the bug: keep the workaround and record the tested
# version in docs/adr/0022-clickhouse-lts-upgrade.md.
#
# Requires: the stack up (docker compose up) and silver-layer parquet already
# published to MinIO (i.e. the pipeline has run at least once), since the
# staging views read s3://data-lake/silver/*.

# .env has plain KEY=VALUE lines (no `export`); re-source with `set -a` so
# CLICKHOUSE_USER / CLICKHOUSE_PASSWORD are exported into this process.
# Same pattern as scripts/verify-clickhouse.sh.
set -a
source .env
set +a

# Credentials go through --netrc-file, not embedded in the URL: a URL-embedded
# user:pass@host is visible to any local user via `ps aux` while curl runs.
CH_NETRC=$(mktemp)
trap 'rm -f "$CH_NETRC"' EXIT
chmod 600 "$CH_NETRC"
printf 'machine localhost login %s password %s\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" > "$CH_NETRC"

# Host-side port is 8124, not 8123 - see docker-compose.yml's clickhouse
# service ports mapping (8123 is taken by a local socksproxy.exe service).
CH_URL="http://localhost:8124/"

run_sql() {
  curl -sf --netrc-file "$CH_NETRC" "$CH_URL" --data-binary @-
}

echo "ClickHouse s3()-view join bug repro (ADR-0022)"
echo "Step 1/3: baseline from single-view scans (known-good path)..."

# The `transaction_id IN (SELECT ...)` semi-joins below only test set
# membership - no columns are joined IN, which is the operation the bug
# corrupts - and the matched-id count is cross-checked from both directions
# (partner->bank and bank->partner must agree).
PARTNER_BASE=$(run_sql <<'EOSQL'
SELECT
    count(*) AS partner_rows,
    count(*) - count(DISTINCT transaction_id) AS duplicate_ids,
    countIf(transaction_id IN (SELECT transaction_id FROM stg_bank_transactions)) AS matched_ids,
    countIf(bank_id IS NOT NULL AND transaction_id IN (SELECT transaction_id FROM stg_bank_transactions)) AS matched_nonnull_bank_id,
    countIf(decline_reason IS NOT NULL AND transaction_id IN (SELECT transaction_id FROM stg_bank_transactions)) AS matched_nonnull_decline_reason
FROM stg_partner_transactions
FORMAT TabSeparated
EOSQL
)
P_ROWS=$(echo "$PARTNER_BASE" | cut -f1)
P_DUPES=$(echo "$PARTNER_BASE" | cut -f2)
MATCHED_P=$(echo "$PARTNER_BASE" | cut -f3)
EXP_P_BANK_ID=$(echo "$PARTNER_BASE" | cut -f4)
EXP_DECLINE_REASON=$(echo "$PARTNER_BASE" | cut -f5)

BANK_BASE=$(run_sql <<'EOSQL'
SELECT
    count(*) AS bank_rows,
    count(*) - count(DISTINCT transaction_id) AS duplicate_ids,
    countIf(transaction_id IN (SELECT transaction_id FROM stg_partner_transactions)) AS matched_ids,
    countIf(bank_id IS NOT NULL AND transaction_id IN (SELECT transaction_id FROM stg_partner_transactions)) AS matched_nonnull_bank_id,
    countIf(decline_reason IS NOT NULL AND transaction_id IN (SELECT transaction_id FROM stg_partner_transactions)) AS matched_nonnull_bank_decline_reason
FROM stg_bank_transactions
FORMAT TabSeparated
EOSQL
)
B_ROWS=$(echo "$BANK_BASE" | cut -f1)
B_DUPES=$(echo "$BANK_BASE" | cut -f2)
MATCHED_B=$(echo "$BANK_BASE" | cut -f3)
EXP_B_BANK_ID=$(echo "$BANK_BASE" | cut -f4)
EXP_BANK_DECLINE_REASON=$(echo "$BANK_BASE" | cut -f5)

if [ "${P_ROWS:-0}" -lt 1 ] || [ "${B_ROWS:-0}" -lt 1 ]; then
  echo "FAIL: staging views are empty (partner=${P_ROWS:-0}, bank=${B_ROWS:-0}) - run the pipeline first so silver parquet exists; the repro is meaningless on empty views"
  exit 1
fi
if [ "${P_DUPES:-1}" -ne 0 ] || [ "${B_DUPES:-1}" -ne 0 ]; then
  echo "FAIL: duplicate transaction_ids in staging views (partner=${P_DUPES}, bank=${B_DUPES}) - the count-based comparison below assumes unique ids per side"
  exit 1
fi
if [ "${MATCHED_P:-0}" -ne "${MATCHED_B:-1}" ]; then
  echo "FAIL: matched-id count disagrees between directions (partner->bank=${MATCHED_P}, bank->partner=${MATCHED_B}) - baseline itself is unreliable, cannot trust this repro"
  exit 1
fi
if [ "${MATCHED_P:-0}" -lt 1 ]; then
  echo "FAIL: no transaction_ids exist on both sides - the repro is vacuous; load mock data with Partner/Bank overlap first"
  exit 1
fi

echo "  baseline: ${P_ROWS} partner rows, ${B_ROWS} bank rows, ${MATCHED_P} matched ids"
echo "  expected non-NULL among matched: partner.bank_id=${EXP_P_BANK_ID}, bank.bank_id=${EXP_B_BANK_ID}, decline_reason=${EXP_DECLINE_REASON}, bank_decline_reason=${EXP_BANK_DECLINE_REASON}"

for COL_CHECK in "partner.bank_id=${EXP_P_BANK_ID}" "bank.bank_id=${EXP_B_BANK_ID}" "decline_reason=${EXP_DECLINE_REASON}" "bank_decline_reason=${EXP_BANK_DECLINE_REASON}"; do
  if [ "${COL_CHECK#*=}" -lt 1 ]; then
    echo "  WARN: no matched row has a non-NULL ${COL_CHECK%=*} - that column's silent-NULL check is vacuous on this dataset"
  fi
done

echo "Step 2/3: direct FULL OUTER JOIN of the s3()-backed views (the suspect operation)..."

# Mirrors int_reconciled_transactions.sql's projection so the bug's
# column-count sensitivity has (approximately) the same surface area, except:
# both transaction_ids and both bank_ids are kept separate instead of
# coalesced, so each side's value can be checked independently.
JOIN_RESULT=$(run_sql <<'EOSQL'
WITH joined AS (
    SELECT
        p.transaction_id AS p_tid,
        b.transaction_id AS b_tid,
        coalesce(p.partner_id, b.partner_id) AS partner_id,
        coalesce(p.amount_cents, b.amount_cents) AS amount_cents,
        coalesce(p.currency, b.currency) AS currency,
        p.state AS state,
        p.decline_reason AS decline_reason,
        p.initiated_at AS initiated_at,
        p.authorized_at AS authorized_at,
        p.captured_at AS captured_at,
        p.settled_at AS settled_at,
        p.failed_at AS failed_at,
        p.refunded_at AS refunded_at,
        p.bank_id AS p_bank_id,
        b.bank_id AS b_bank_id,
        b.state AS bank_state,
        b.decline_reason AS bank_decline_reason,
        b.authorized_at AS bank_authorized_at,
        b.captured_at AS bank_captured_at,
        b.settled_at AS bank_settled_at,
        b.failed_at AS bank_failed_at
    FROM stg_partner_transactions AS p
    FULL OUTER JOIN stg_bank_transactions AS b
        ON p.transaction_id = b.transaction_id
)
SELECT
    count(*) AS total_rows,
    countIf(p_tid IS NOT NULL AND b_tid IS NOT NULL) AS matched_rows,
    countIf(p_tid IS NOT NULL AND b_tid IS NOT NULL AND p_bank_id IS NOT NULL) AS matched_nonnull_p_bank_id,
    countIf(p_tid IS NOT NULL AND b_tid IS NOT NULL AND b_bank_id IS NOT NULL) AS matched_nonnull_b_bank_id,
    countIf(p_tid IS NOT NULL AND b_tid IS NOT NULL AND decline_reason IS NOT NULL) AS matched_nonnull_decline_reason,
    countIf(p_tid IS NOT NULL AND b_tid IS NOT NULL AND bank_decline_reason IS NOT NULL) AS matched_nonnull_bank_decline_reason
FROM joined
FORMAT TabSeparated
EOSQL
)
J_TOTAL=$(echo "$JOIN_RESULT" | cut -f1)
J_MATCHED=$(echo "$JOIN_RESULT" | cut -f2)
J_P_BANK_ID=$(echo "$JOIN_RESULT" | cut -f3)
J_B_BANK_ID=$(echo "$JOIN_RESULT" | cut -f4)
J_DECLINE_REASON=$(echo "$JOIN_RESULT" | cut -f5)
J_BANK_DECLINE_REASON=$(echo "$JOIN_RESULT" | cut -f6)

echo "Step 3/3: comparing join output against baseline..."

FAILURES=0
fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

# Row-shape checks first: if the join NULLed a transaction_id, a matched row
# gets misclassified as an orphan, so matched_rows drops below the baseline
# even though total row count stays P + B - matched.
EXPECTED_TOTAL=$((P_ROWS + B_ROWS - MATCHED_P))
if [ "${J_TOTAL:-0}" -ne "$EXPECTED_TOTAL" ]; then
  fail "join returned ${J_TOTAL} rows, expected ${EXPECTED_TOTAL} (${P_ROWS} + ${B_ROWS} - ${MATCHED_P} matched)"
fi
if [ "${J_MATCHED:-0}" -ne "$MATCHED_P" ]; then
  fail "join classified ${J_MATCHED} rows as matched-on-both-sides, baseline says ${MATCHED_P} - transaction_id itself was silently NULLed on $((MATCHED_P - J_MATCHED)) matched row(s)"
fi

check_column() {
  local name=$1 expected=$2 actual=$3
  if [ "${actual:-0}" -lt "$expected" ]; then
    fail "SILENT NULL in '${name}': only ${actual} of ${expected} matched rows kept their non-NULL value - the s3()-view join bug is PRESENT on this ClickHouse version"
  fi
}
check_column "bank_id (partner side)" "$EXP_P_BANK_ID" "$J_P_BANK_ID"
check_column "bank_id (bank side)" "$EXP_B_BANK_ID" "$J_B_BANK_ID"
check_column "decline_reason" "$EXP_DECLINE_REASON" "$J_DECLINE_REASON"
check_column "bank_decline_reason" "$EXP_BANK_DECLINE_REASON" "$J_BANK_DECLINE_REASON"

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "################################################################"
  echo "## FAIL: ${FAILURES} check(s) failed - joins against s3()-backed"
  echo "## views STILL silently NULL columns on this ClickHouse version."
  echo "## DO NOT remove the int_partner_transactions /"
  echo "## int_bank_transactions workaround models. Record the tested"
  echo "## version in docs/adr/0022-clickhouse-lts-upgrade.md."
  echo "################################################################"
  exit 1
fi

echo "PASS: direct FULL OUTER JOIN of the s3()-backed staging views preserved all ${MATCHED_P} matched rows and every checked column (bank_id both sides, decline_reason, bank_decline_reason) - the workaround snapshot models are safe to retire per ADR-0022"
