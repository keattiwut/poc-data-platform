#!/usr/bin/env bash
set -euo pipefail

if [ -f .env ]; then
  set -a; source .env; set +a
fi

: "${SUPERSET_ADMIN_USER:?SUPERSET_ADMIN_USER not set - source .env first}"
: "${SUPERSET_ADMIN_PASSWORD:?SUPERSET_ADMIN_PASSWORD not set - source .env first}"
: "${CLICKHOUSE_USER:?CLICKHOUSE_USER not set - source .env first}"
: "${CLICKHOUSE_PASSWORD:?CLICKHOUSE_PASSWORD not set - source .env first}"

SUPERSET_URL="${SUPERSET_URL:-http://localhost:8088}"

echo "Waiting for Superset to be reachable at ${SUPERSET_URL}..."
READY=0
for _ in $(seq 1 30); do
  if curl -sf "${SUPERSET_URL}/health" > /dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
[ "$READY" -eq 1 ] || { echo "ERROR: Superset unreachable at ${SUPERSET_URL}" >&2; exit 1; }

echo "Authenticating against Superset's API..."
source scripts/superset-auth.sh   # exports SUPERSET_ACCESS_TOKEN
TOKEN="$SUPERSET_ACCESS_TOKEN"

# --- CSRF handling ------------------------------------------------------
# Superset's write endpoints (POST/PUT) require an X-CSRFToken header in
# addition to the bearer token. Empirically verified against the running
# 4.1.1 instance: GET /api/v1/security/csrf_token/ returns the token value
# AND sets a `session` cookie carrying the matching server-side secret; a
# write request must send BOTH the X-CSRFToken header and that session
# cookie back, or Superset rejects it with:
#   400 Bad Request: The CSRF session token is missing.
# The bearer token alone is not sufficient for these routes.
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT
CSRF_TOKEN=$(curl -sf -c "$COOKIE_JAR" -H "Authorization: Bearer ${TOKEN}" \
  "${SUPERSET_URL}/api/v1/security/csrf_token/" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])")
[ -n "$CSRF_TOKEN" ] || { echo "ERROR: failed to obtain CSRF token" >&2; exit 1; }

# --- HTTP helpers with real diagnostics on failure -----------------------
# curl -sf silently swallows the response body on failure. This helper
# captures both the HTTP status and body; on non-2xx it prints both to
# stderr and returns 1.
http_call() {
  # Usage: http_call METHOD PATH [DATA]
  local method="$1" path="$2" data="${3:-}"
  local resp_file status body
  resp_file=$(mktemp)
  local curl_opts=(-s -o "$resp_file" -w '%{http_code}' -X "$method" \
    "${SUPERSET_URL}${path}" -H "Authorization: Bearer ${TOKEN}")
  if [ "$method" != "GET" ]; then
    curl_opts+=(-b "$COOKIE_JAR" -H "X-CSRFToken: ${CSRF_TOKEN}")
  fi
  if [ -n "$data" ]; then
    curl_opts+=(-H "Content-Type: application/json" -d "$data")
  fi
  status=$(curl "${curl_opts[@]}")
  body=$(cat "$resp_file")
  rm -f "$resp_file"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "ERROR: ${method} ${path} failed with HTTP ${status}" >&2
    echo "Response body:" >&2
    echo "$body" >&2
    return 1
  fi
  echo "$body"
}
# GET list endpoints filtered by `q=(filters:...)` need the query string
# URL-encoded (see verify-superset-chart.sh for why: a raw space in the URL
# makes curl fail with "Malformed input" before the request is even sent).
api_get_filtered() {
  # Usage: api_get_filtered PATH RISON_QUERY
  local path="$1" query="$2"
  local resp_file status body
  resp_file=$(mktemp)
  status=$(curl -s -o "$resp_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    -G --data-urlencode "q=${query}" "${SUPERSET_URL}${path}")
  body=$(cat "$resp_file")
  rm -f "$resp_file"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "ERROR: GET ${path}?q=${query} failed with HTTP ${status}" >&2
    echo "Response body:" >&2
    echo "$body" >&2
    return 1
  fi
  echo "$body"
}
api_post() { http_call POST "$1" "$2"; }
api_put()  { http_call PUT  "$1" "$2"; }

# --- Database (check-before-create) ---------------------------------------
DB_NAME="ClickHouse"
# Container-internal ClickHouse port is 8123 on the Compose service name
# "clickhouse" - NOT the host-remapped 8124 from Issue 01's port-conflict
# fix. Superset and ClickHouse talk to each other over the Compose network,
# not through the host's remapped port.
SQLALCHEMY_URI="clickhousedb://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@clickhouse:8123/default"

echo "Checking for existing '${DB_NAME}' database connection..."
DB_SEARCH=$(api_get_filtered "/api/v1/database/" "(filters:!((col:database_name,opr:eq,value:'${DB_NAME}')))") || exit 1
DB_ID=$(echo "$DB_SEARCH" | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')

if [ -z "$DB_ID" ]; then
  echo "Creating '${DB_NAME}' database connection (clickhouse-connect driver, clickhousedb:// dialect)..."
  DB_PAYLOAD=$(SQLALCHEMY_URI="$SQLALCHEMY_URI" DB_NAME="$DB_NAME" python3 -c '
import json, os
print(json.dumps({
    "database_name": os.environ["DB_NAME"],
    "sqlalchemy_uri": os.environ["SQLALCHEMY_URI"],
}))
')
  DB_RESPONSE=$(api_post "/api/v1/database/" "$DB_PAYLOAD") || exit 1
  DB_ID=$(echo "$DB_RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
else
  echo "Found existing database ${DB_ID}; refreshing its connection URI..."
  UPDATE_DB_PAYLOAD=$(SQLALCHEMY_URI="$SQLALCHEMY_URI" python3 -c '
import json, os
print(json.dumps({"sqlalchemy_uri": os.environ["SQLALCHEMY_URI"]}))
')
  api_put "/api/v1/database/${DB_ID}" "$UPDATE_DB_PAYLOAD" > /dev/null || exit 1
fi
echo "Database: ${DB_ID}"

# --- Dataset (check-before-create) -----------------------------------------
TABLE_NAME="fct_transactions_current"

echo "Checking for existing '${TABLE_NAME}' dataset..."
DATASET_SEARCH=$(api_get_filtered "/api/v1/dataset/" "(filters:!((col:table_name,opr:eq,value:${TABLE_NAME})))") || exit 1
DATASET_ID=$(echo "$DATASET_SEARCH" | DB_ID="$DB_ID" python3 -c '
import sys, json, os
result = json.load(sys.stdin)["result"]
db_id = int(os.environ["DB_ID"])
match = [d["id"] for d in result if d.get("database", {}).get("id") == db_id]
print(match[0] if match else "")
')

if [ -z "$DATASET_ID" ]; then
  echo "Creating '${TABLE_NAME}' dataset on database ${DB_ID}..."
  DATASET_PAYLOAD=$(DB_ID="$DB_ID" TABLE_NAME="$TABLE_NAME" python3 -c '
import json, os
print(json.dumps({
    "database": int(os.environ["DB_ID"]),
    "table_name": os.environ["TABLE_NAME"],
    "schema": "default",
}))
')
  DATASET_RESPONSE=$(api_post "/api/v1/dataset/" "$DATASET_PAYLOAD") || exit 1
  DATASET_ID=$(echo "$DATASET_RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
else
  echo "Found existing dataset ${DATASET_ID}"
fi
echo "Dataset: ${DATASET_ID}"

# --- Chart (check-before-create) --------------------------------------------
CHART_NAME="Transaction Volume by Day"

# Daily transaction count, grouped by initiated_at truncated to day.
# Verified against the running instance: Superset's ClickHouse engine spec
# (superset/db_engine_specs/clickhouse.py) renders the "P1D" time grain as
# `toStartOfDay(toDateTime(initiated_at))`, which is the day-truncation this
# chart needs. `params` is the Explore-UI form config for viz_type
# echarts_timeseries_bar (x_axis + time_grain_sqla, the standard fields for
# that viz type); `query_context` is the resolved backend query object -
# empirically confirmed via POST /api/v1/chart/data (see task-6-report.md)
# to produce:
#   SELECT toStartOfDay(toDateTime(`initiated_at`)) AS `__timestamp`,
#          COUNT(*) AS `count`
#   FROM `default`.`fct_transactions_current` GROUP BY `__timestamp`
# Saving query_context up front (rather than leaving it unset) means the
# chart renders real data immediately instead of erroring with "Chart has
# no query context saved" the first time someone opens it.
CHART_PARAMS=$(python3 -c '
import json
print(json.dumps({
    "datasource": "%DATASOURCE%",
    "viz_type": "echarts_timeseries_bar",
    "x_axis": "initiated_at",
    "time_grain_sqla": "P1D",
    "metrics": ["count"],
    "groupby": [],
    "adhoc_filters": [],
    "row_limit": 10000,
}))
' | sed "s/%DATASOURCE%/${DATASET_ID}__table/")

CHART_QUERY_CONTEXT=$(DATASET_ID="$DATASET_ID" python3 -c '
import json, os
dataset_id = int(os.environ["DATASET_ID"])
print(json.dumps({
    "datasource": {"id": dataset_id, "type": "table"},
    "force": False,
    "queries": [{
        "granularity": "initiated_at",
        "metrics": ["count"],
        "groupby": [],
        "columns": ["__timestamp"],
        "extras": {"time_grain_sqla": "P1D"},
        "orderby": [],
        "annotation_layers": [],
        "row_limit": 10000,
        "order_desc": True,
        "time_offsets": [],
        "post_processing": [],
        "time_range": "No filter",
        "is_timeseries": True,
    }],
    "form_data": {
        "datasource": f"{dataset_id}__table",
        "viz_type": "echarts_timeseries_bar",
        "x_axis": "initiated_at",
        "granularity_sqla": "initiated_at",
        "time_grain_sqla": "P1D",
        "metrics": ["count"],
        "groupby": [],
        "adhoc_filters": [],
        "row_limit": 10000,
    },
    "result_format": "json",
    "result_type": "full",
}))
')

echo "Checking for existing '${CHART_NAME}' chart..."
CHART_SEARCH=$(api_get_filtered "/api/v1/chart/" "(filters:!((col:slice_name,opr:eq,value:'${CHART_NAME}')))") || exit 1
CHART_ID=$(echo "$CHART_SEARCH" | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')

if [ -z "$CHART_ID" ]; then
  echo "Creating '${CHART_NAME}' chart on dataset ${DATASET_ID}..."
  CHART_PAYLOAD=$(CHART_NAME="$CHART_NAME" DATASET_ID="$DATASET_ID" CHART_PARAMS="$CHART_PARAMS" CHART_QUERY_CONTEXT="$CHART_QUERY_CONTEXT" python3 -c '
import json, os
print(json.dumps({
    "slice_name": os.environ["CHART_NAME"],
    "viz_type": "echarts_timeseries_bar",
    "datasource_id": int(os.environ["DATASET_ID"]),
    "datasource_type": "table",
    "params": os.environ["CHART_PARAMS"],
    "query_context": os.environ["CHART_QUERY_CONTEXT"],
    "query_context_generation": True,
}))
')
  CHART_RESPONSE=$(api_post "/api/v1/chart/" "$CHART_PAYLOAD") || exit 1
  CHART_ID=$(echo "$CHART_RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
else
  echo "Found existing chart ${CHART_ID}; refreshing its params/query_context..."
  UPDATE_CHART_PAYLOAD=$(CHART_PARAMS="$CHART_PARAMS" CHART_QUERY_CONTEXT="$CHART_QUERY_CONTEXT" python3 -c '
import json, os
print(json.dumps({
    "params": os.environ["CHART_PARAMS"],
    "query_context": os.environ["CHART_QUERY_CONTEXT"],
    "query_context_generation": True,
}))
')
  api_put "/api/v1/chart/${CHART_ID}" "$UPDATE_CHART_PAYLOAD" > /dev/null || exit 1
fi
echo "Chart: ${CHART_ID}"

# --- Dashboard (check-before-create) ----------------------------------------
DASHBOARD_TITLE="Transaction Volume"

echo "Checking for existing '${DASHBOARD_TITLE}' dashboard..."
DASHBOARD_SEARCH=$(api_get_filtered "/api/v1/dashboard/" "(filters:!((col:dashboard_title,opr:eq,value:'${DASHBOARD_TITLE}')))") || exit 1
DASHBOARD_ID=$(echo "$DASHBOARD_SEARCH" | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')

if [ -z "$DASHBOARD_ID" ]; then
  echo "Creating '${DASHBOARD_TITLE}' dashboard..."
  DASHBOARD_PAYLOAD=$(DASHBOARD_TITLE="$DASHBOARD_TITLE" python3 -c '
import json, os
print(json.dumps({"dashboard_title": os.environ["DASHBOARD_TITLE"], "slug": "transaction-volume"}))
')
  DASHBOARD_RESPONSE=$(api_post "/api/v1/dashboard/" "$DASHBOARD_PAYLOAD") || exit 1
  DASHBOARD_ID=$(echo "$DASHBOARD_RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
else
  echo "Found existing dashboard ${DASHBOARD_ID}"
fi
echo "Dashboard: ${DASHBOARD_ID}"

# --- Attach chart to dashboard (idempotent: re-PUTting the same
# association is a no-op) ----------------------------------------------------
echo "Attaching chart ${CHART_ID} to dashboard ${DASHBOARD_ID}..."
ATTACH_PAYLOAD=$(DASHBOARD_ID="$DASHBOARD_ID" python3 -c '
import json, os
print(json.dumps({"dashboards": [int(os.environ["DASHBOARD_ID"])]}))
')
api_put "/api/v1/chart/${CHART_ID}" "$ATTACH_PAYLOAD" > /dev/null || exit 1

# --- Dashboard layout: put the chart on the grid so it actually renders
# when opened, instead of an empty dashboard that merely "owns" the chart
# via the many-to-many relation set above. ----------------------------------
POSITION_JSON=$(CHART_ID="$CHART_ID" CHART_NAME="$CHART_NAME" python3 -c '
import json, os
chart_id = int(os.environ["CHART_ID"])
chart_key = f"CHART-{chart_id}"
position = {
    "DASHBOARD_VERSION_KEY": "v2",
    "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"]},
    "GRID_ID": {
        "type": "GRID",
        "id": "GRID_ID",
        "children": ["ROW-1"],
        "parents": ["ROOT_ID"],
    },
    "ROW-1": {
        "type": "ROW",
        "id": "ROW-1",
        "children": [chart_key],
        "parents": ["ROOT_ID", "GRID_ID"],
        "meta": {"background": "BACKGROUND_TRANSPARENT"},
    },
    chart_key: {
        "type": "CHART",
        "id": chart_key,
        "children": [],
        "parents": ["ROOT_ID", "GRID_ID", "ROW-1"],
        "meta": {
            "chartId": chart_id,
            "width": 12,
            "height": 50,
            "sliceName": os.environ["CHART_NAME"],
        },
    },
}
print(json.dumps(position))
')
DASHBOARD_UPDATE_PAYLOAD=$(POSITION_JSON="$POSITION_JSON" python3 -c '
import json, os
print(json.dumps({"position_json": os.environ["POSITION_JSON"]}))
')
api_put "/api/v1/dashboard/${DASHBOARD_ID}" "$DASHBOARD_UPDATE_PAYLOAD" > /dev/null || exit 1

echo "PASS: ClickHouse database (${DB_ID}), dataset (${DATASET_ID}), chart '${CHART_NAME}' (${CHART_ID}), and dashboard '${DASHBOARD_TITLE}' (${DASHBOARD_ID}) are configured in Superset"
