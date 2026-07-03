#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking a chart named 'Transaction Volume by Day' exists in Superset..."
# Superset's REST API requires a login (access token) + CSRF token first; see
# scripts/configure-superset-clickhouse.sh for the auth flow this reuses.
source scripts/superset-auth.sh  # expected to export SUPERSET_ACCESS_TOKEN

# NOTE: `q=(...)` must be sent through `-G --data-urlencode`, not embedded
# directly in the URL string. Empirically verified against the running
# instance: a literal space in "Transaction Volume by Day" inside a raw URL
# makes curl fail with "curl: (3) URL rejected: Malformed input" before the
# request is even sent - the space has to be percent-encoded.
CHART_SEARCH=$(curl -sf -H "Authorization: Bearer ${SUPERSET_ACCESS_TOKEN}" \
  -G --data-urlencode "q=(filters:!((col:slice_name,opr:eq,value:'Transaction Volume by Day')))" \
  "http://localhost:8088/api/v1/chart/")

CHART_COUNT=$(echo "$CHART_SEARCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")

if [ "${CHART_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no chart named 'Transaction Volume by Day' found"
  exit 1
fi

echo "PASS: found the Transaction Volume by Day chart in Superset"

# --- Chart data check --------------------------------------------------------
# Existence alone doesn't prove the chart can render real data - its
# datasource/database connection could be broken while the chart object
# itself is fine. Pull the chart's id and hit its data endpoint
# (GET /api/v1/chart/<id>/data/), which executes the chart's saved
# query_context against ClickHouse and returns real rows. Response shape
# empirically confirmed in task-6-report.md:
#   {"result": [{"status": "success", "data": [{"__timestamp": ..., "count": 188}, ...], ...}]}
# (one entry in "result" per query in the chart's query_context; this chart
# has exactly one query, grouping COUNT(*) by day via the "count" metric.)
CHART_ID=$(echo "$CHART_SEARCH" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")

echo "Checking chart ${CHART_ID} returns real data from ClickHouse..."
# force=true bypasses Superset's query-result cache so this compares against
# a fresh execution, not a stale cached result from an earlier dataset size.
CHART_DATA=$(curl -sf -H "Authorization: Bearer ${SUPERSET_ACCESS_TOKEN}" \
  -G --data-urlencode "force=true" \
  "http://localhost:8088/api/v1/chart/${CHART_ID}/data/")

CHART_DATA_STATUS=$(echo "$CHART_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['status'])")
if [ "$CHART_DATA_STATUS" != "success" ]; then
  echo "FAIL: chart data query did not succeed (status=${CHART_DATA_STATUS})"
  echo "$CHART_DATA"
  exit 1
fi

CHART_ROW_COUNT=$(echo "$CHART_DATA" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result'][0]['data']))")
if [ "${CHART_ROW_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: chart data query succeeded but returned zero rows - chart is not rendering real data"
  exit 1
fi

CHART_DATA_TOTAL=$(echo "$CHART_DATA" | python3 -c "import sys,json; print(sum(row['count'] for row in json.load(sys.stdin)['result'][0]['data']))")

# Compare against a live count query against fct_transactions_current itself
# (same approach as verify-fct-transactions.sh), rather than a hardcoded
# expected number - the dataset grows across re-runs during this branch's
# development.
# Credentials go through --netrc-file, not embedded in the URL - see
# scripts/verify-clickhouse.sh for why (visible in `ps aux` otherwise).
CH_NETRC=$(mktemp)
trap 'rm -f "$CH_NETRC"' EXIT
chmod 600 "$CH_NETRC"
printf 'machine localhost login %s password %s\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" > "$CH_NETRC"

CLICKHOUSE_TOTAL=$(curl -sf --netrc-file "$CH_NETRC" "http://localhost:8124/" --data-binary @- <<'EOSQL'
SELECT count(*) FROM fct_transactions_current
EOSQL
)

if [ "$CHART_DATA_TOTAL" -ne "$CLICKHOUSE_TOTAL" ]; then
  echo "FAIL: chart data row counts sum to ${CHART_DATA_TOTAL}, but fct_transactions_current has ${CLICKHOUSE_TOTAL} rows - chart data is stale or wrong"
  exit 1
fi

echo "PASS: chart ${CHART_ID} returns ${CHART_ROW_COUNT} day-grouped row(s) from ClickHouse summing to ${CHART_DATA_TOTAL}, matching fct_transactions_current's live row count"
