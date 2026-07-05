#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking a chart named 'Transaction Volume by Day' exists in Superset..."
# Superset's REST API requires a login (access token) + CSRF token first; see
# scripts/configure-superset-clickhouse.sh for the auth flow this reuses.
source scripts/superset-auth.sh  # expected to export SUPERSET_ACCESS_TOKEN

# --- Reusable chart existence + data check --------------------------------
# NOTE: `q=(...)` must be sent through `-G --data-urlencode`, not embedded
# directly in the URL string. Empirically verified against the running
# instance: a literal space in "Transaction Volume by Day" inside a raw URL
# makes curl fail with "curl: (3) URL rejected: Malformed input" before the
# request is even sent - the space has to be percent-encoded.
#
# Existence alone doesn't prove the chart can render real data - its
# datasource/database connection could be broken while the chart object
# itself is fine. Pull the chart's id and hit its data endpoint
# (GET /api/v1/chart/<id>/data/), which executes the chart's saved
# query_context against ClickHouse and returns real rows. Response shape
# empirically confirmed in task-6-report.md:
#   {"result": [{"status": "success", "data": [{"__timestamp": ..., "count": 188}, ...], ...}]}
# (one entry in "result" per query in the chart's query_context.)
check_chart_has_data() {
  local chart_name="$1"
  echo "Checking a chart named '${chart_name}' exists in Superset..."
  local chart_search
  chart_search=$(curl -sf -H "Authorization: Bearer ${SUPERSET_ACCESS_TOKEN}" \
    -G --data-urlencode "q=(filters:!((col:slice_name,opr:eq,value:'${chart_name}')))" \
    "http://localhost:8088/api/v1/chart/")

  local chart_count
  chart_count=$(echo "$chart_search" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")
  if [ "${chart_count:-0}" -lt 1 ]; then
    echo "FAIL: no chart named '${chart_name}' found"
    exit 1
  fi

  local chart_id
  chart_id=$(echo "$chart_search" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")

  echo "Checking chart ${chart_id} ('${chart_name}') returns real data from ClickHouse..."
  # force=true bypasses Superset's query-result cache so this compares
  # against a fresh execution, not a stale cached result.
  local chart_data
  chart_data=$(curl -sf -H "Authorization: Bearer ${SUPERSET_ACCESS_TOKEN}" \
    -G --data-urlencode "force=true" \
    "http://localhost:8088/api/v1/chart/${chart_id}/data/")

  local status
  status=$(echo "$chart_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['status'])")
  if [ "$status" != "success" ]; then
    echo "FAIL: chart '${chart_name}' data query did not succeed (status=${status})"
    echo "$chart_data"
    exit 1
  fi

  local row_count
  row_count=$(echo "$chart_data" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result'][0]['data']))")
  if [ "${row_count:-0}" -lt 1 ]; then
    echo "FAIL: chart '${chart_name}' returned zero rows"
    exit 1
  fi

  echo "PASS: chart '${chart_name}' returns real data (${row_count} row(s))"
  # Export chart_data for callers that want to do extra checks (e.g. the
  # "Transaction Volume by Day" cross-check below).
  LAST_CHART_DATA="$chart_data"
}

check_chart_has_data "Transaction Volume by Day"

# --- Stronger check for "Transaction Volume by Day": cross-check its summed
# count against a live ClickHouse query, rather than a hardcoded expected
# number - the dataset grows across re-runs during this branch's
# development. ---------------------------------------------------------------
CHART_DATA_TOTAL=$(echo "$LAST_CHART_DATA" | python3 -c "import sys,json; print(sum(row['count'] for row in json.load(sys.stdin)['result'][0]['data']))")

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
  echo "FAIL: 'Transaction Volume by Day' chart data row counts sum to ${CHART_DATA_TOTAL}, but fct_transactions_current has ${CLICKHOUSE_TOTAL} rows - chart data is stale or wrong"
  exit 1
fi
echo "PASS: 'Transaction Volume by Day' chart data sums to ${CHART_DATA_TOTAL}, matching fct_transactions_current's live row count"

check_chart_has_data "Authorization Rate"
check_chart_has_data "Settlement Rate"
check_chart_has_data "Gross Revenue"

echo "PASS: all four charts exist and return real data"
