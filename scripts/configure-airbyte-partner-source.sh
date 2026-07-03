#!/usr/bin/env bash
set -euo pipefail

# --- WSL2 dispatch -------------------------------------------------------
# abctl (used below to fetch Airbyte's API application credentials) does
# not support native Windows. Same pattern as scripts/install-airbyte.sh
# and scripts/verify-airbyte.sh: re-exec inside WSL2 if invoked from a
# native Windows shell (Git Bash/MSYS). No-op on WSL2/Linux/macOS.
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  echo "Detected native Windows shell - re-executing inside WSL2 (per Airbyte's guidance)..."
  WIN_DIR="$(pwd -W)"
  DRIVE="$(echo "${WIN_DIR:0:1}" | tr 'A-Z' 'a-z')"
  WSL_DIR="/mnt/${DRIVE}${WIN_DIR:2}"
  exec wsl.exe -d Ubuntu -- bash -lc "cd '${WSL_DIR}' && ./scripts/configure-airbyte-partner-source.sh"
fi
# ---------------------------------------------------------------------------

# NOTE on JSON tooling: this script uses `python3` (not `jq`) to build and
# parse JSON. `jq` is available on the Windows host but is not installed in
# the WSL2 distro this script re-execs into (and installing it requires a
# sudo password we don't have non-interactively), whereas `python3` is
# already present there (it's an abctl/Airbyte prerequisite).

if [ -f .env ]; then
  set -a; source .env; set +a
fi

: "${POSTGRES_USER:?POSTGRES_USER not set - source .env first}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set - source .env first}"
: "${POSTGRES_DB:?POSTGRES_DB not set - source .env first}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set - source .env first}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set - source .env first}"

AIRBYTE_URL="${AIRBYTE_URL:-http://localhost:8000}"
API="${AIRBYTE_URL}/api/public/v1"

# --- Networking note -------------------------------------------------------
# Airbyte's pods run in a separate `kind` Kubernetes cluster (ADR-0020), a
# different Docker network than docker-compose's `payment-gateway-net`, so
# the Compose service names `postgres`/`minio` do not resolve there.
#
# Empirically verified (see .superpowers/sdd/task-2-report.md for the full
# investigation): this machine's abctl/kind cluster and the docker-compose
# services run under the same Docker Desktop daemon, and `host.docker.internal`
# resolves inside kind's pods (to the Docker Desktop VM's host-reachable
# address) and successfully reaches the Compose services' published host
# ports. Confirmed via a debug pod: MinIO's health endpoint returned HTTP 200
# and a raw TCP connect to port 5432 succeeded.
export POSTGRES_REACHABLE_HOST="host.docker.internal"
export MINIO_REACHABLE_HOST="host.docker.internal"
export POSTGRES_PORT_FOR_AIRBYTE="${POSTGRES_PORT:-5432}"
export MINIO_PORT_FOR_AIRBYTE=9000
# ---------------------------------------------------------------------------

echo "Waiting for Airbyte API to be reachable at ${AIRBYTE_URL}..."
READY=0
for _ in $(seq 1 30); do
  if curl -sf "${AIRBYTE_URL}/api/v1/health" > /dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
[ "$READY" -eq 1 ] || { echo "ERROR: Airbyte API unreachable at ${AIRBYTE_URL}" >&2; exit 1; }

echo "Fetching Airbyte API application credentials via abctl..."
command -v abctl > /dev/null || { echo "ERROR: abctl not found (needed to fetch API credentials)" >&2; exit 1; }
# abctl always emits ANSI color codes, even when piped; strip them before parsing.
CREDS_RAW=$(abctl local credentials 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g')
CLIENT_ID=$(echo "$CREDS_RAW" | sed -n 's/.*Client-Id: *//p' | tr -d '\r' | xargs)
CLIENT_SECRET=$(echo "$CREDS_RAW" | sed -n 's/.*Client-Secret: *//p' | tr -d '\r' | xargs)
if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  # Never print CREDS_RAW to stdout/stderr: it contains the live Client-Id,
  # Client-Secret, AND a separate UI login password. Instead, write it to a
  # git-ignored debug file (.superpowers/ is excluded in .gitignore) and
  # report only its path plus non-secret diagnostics.
  DEBUG_DIR=".superpowers/tmp"
  mkdir -p "$DEBUG_DIR"
  DEBUG_FILE="${DEBUG_DIR}/abctl-credentials-raw-$(date +%Y%m%d-%H%M%S).txt"
  echo "$CREDS_RAW" > "$DEBUG_FILE"
  chmod 600 "$DEBUG_FILE" 2>/dev/null || true
  echo "ERROR: could not parse Client-Id/Client-Secret from 'abctl local credentials' output." >&2
  [ -z "$CLIENT_ID" ]     && echo "  - CLIENT_ID is empty" >&2
  [ -z "$CLIENT_SECRET" ] && echo "  - CLIENT_SECRET is empty" >&2
  echo "  - raw output was $(echo "$CREDS_RAW" | wc -l) line(s)" >&2
  echo "  - raw output (contains secrets - do not paste this file into logs/reports/chat) written to: ${DEBUG_FILE}" >&2
  exit 1
fi
export CLIENT_ID CLIENT_SECRET

# --- HTTP helper with real diagnostics on failure ---------------------------
# curl -sf silently swallows the response body on failure, so a bad request
# used to die with either no diagnostic at all, or a confusing downstream
# Python JSONDecodeError from trying to parse an empty/error body as JSON.
# This helper captures both the HTTP status and body; on non-2xx it prints
# both to stderr and returns 1 (call sites below chain `|| exit 1` so the
# script stops right after the diagnostic, before any JSON parsing runs).
http_call() {
  # Usage: http_call METHOD URL [DATA]
  # Adds the Bearer auth header automatically once TOKEN is set/exported.
  local method="$1" url="$2" data="${3:-}"
  local resp_file status body
  resp_file=$(mktemp)
  local curl_opts=(-s -o "$resp_file" -w '%{http_code}' -X "$method" "$url")
  if [ -n "${TOKEN:-}" ]; then
    curl_opts+=(-H "Authorization: Bearer ${TOKEN}")
  fi
  if [ -n "$data" ]; then
    curl_opts+=(-H "Content-Type: application/json" -d "$data")
  fi
  status=$(curl "${curl_opts[@]}")
  body=$(cat "$resp_file")
  rm -f "$resp_file"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "ERROR: ${method} ${url} failed with HTTP ${status}" >&2
    echo "Response body:" >&2
    echo "$body" >&2
    return 1
  fi
  echo "$body"
}
api_get()   { http_call GET   "${API}$1" ""; }
api_post()  { http_call POST  "${API}$1" "$2"; }
api_patch() { http_call PATCH "${API}$1" "$2"; }

echo "Requesting Airbyte API access token (client-credentials grant)..."
TOKEN_PAYLOAD=$(python3 -c 'import json, os; print(json.dumps({"client_id": os.environ["CLIENT_ID"], "client_secret": os.environ["CLIENT_SECRET"]}))')
TOKEN_RESPONSE=$(api_post "/applications/token" "${TOKEN_PAYLOAD}") || exit 1
TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("access_token", ""))')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "ERROR: failed to obtain Airbyte API access token (response did not include access_token)" >&2; exit 1; }
export TOKEN

echo "Looking up default Airbyte workspace..."
WORKSPACES_RESPONSE=$(api_get "/workspaces") || exit 1
WORKSPACE_ID=$(echo "$WORKSPACES_RESPONSE" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"][0]["workspaceId"])')
[ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ] || { echo "ERROR: no Airbyte workspace found" >&2; exit 1; }
echo "Workspace: ${WORKSPACE_ID}"
export WORKSPACE_ID

SOURCE_NAME="partner-transactions-postgres-source"
DEST_NAME="minio-bronze-destination"
export SOURCE_NAME DEST_NAME

# --- Postgres source (check-before-create) ---------------------------------
SOURCE_CONFIG=$(python3 -c '
import json, os
print(json.dumps({
    "sourceType": "postgres",
    "host": os.environ["POSTGRES_REACHABLE_HOST"],
    "port": int(os.environ["POSTGRES_PORT_FOR_AIRBYTE"]),
    "database": os.environ["POSTGRES_DB"],
    "username": os.environ["POSTGRES_USER"],
    "password": os.environ["POSTGRES_PASSWORD"],
    "ssl_mode": {"mode": "disable"},
    "tunnel_method": {"tunnel_method": "NO_TUNNEL"},
    "replication_method": {"method": "Standard"},
}))
')
export SOURCE_CONFIG

echo "Checking for existing Postgres source '${SOURCE_NAME}'..."
SOURCES_RESPONSE=$(api_get "/sources?workspaceIds=${WORKSPACE_ID}") || exit 1
SOURCE_ID=$(echo "$SOURCES_RESPONSE" | python3 -c '
import json, os, sys
data = json.load(sys.stdin)["data"]
match = [s["sourceId"] for s in data if s["name"] == os.environ["SOURCE_NAME"]]
print(match[0] if match else "")
')

if [ -z "$SOURCE_ID" ]; then
  echo "Creating Postgres source pointing at ${POSTGRES_REACHABLE_HOST}:${POSTGRES_PORT_FOR_AIRBYTE}/${POSTGRES_DB}..."
  CREATE_SOURCE_PAYLOAD=$(python3 -c 'import json, os; print(json.dumps({"name": os.environ["SOURCE_NAME"], "workspaceId": os.environ["WORKSPACE_ID"], "configuration": json.loads(os.environ["SOURCE_CONFIG"])}))')
  CREATE_SOURCE_RESPONSE=$(api_post "/sources" "${CREATE_SOURCE_PAYLOAD}") || exit 1
  SOURCE_ID=$(echo "$CREATE_SOURCE_RESPONSE" | python3 -c 'import json, sys; print(json.load(sys.stdin)["sourceId"])')
else
  echo "Found existing source ${SOURCE_ID}; refreshing its configuration..."
  UPDATE_SOURCE_PAYLOAD=$(python3 -c 'import json, os; print(json.dumps({"configuration": json.loads(os.environ["SOURCE_CONFIG"])}))')
  api_patch "/sources/${SOURCE_ID}" "${UPDATE_SOURCE_PAYLOAD}" > /dev/null || exit 1
fi
echo "Source: ${SOURCE_ID}"

# --- S3/MinIO destination (check-before-create) -----------------------------
DEST_CONFIG=$(python3 -c '
import json, os
print(json.dumps({
    "destinationType": "s3",
    "s3_bucket_name": "data-lake",
    "s3_bucket_path": "bronze/partner_transactions",
    "s3_bucket_region": "",
    "s3_endpoint": "http://{}:{}".format(os.environ["MINIO_REACHABLE_HOST"], os.environ["MINIO_PORT_FOR_AIRBYTE"]),
    "access_key_id": os.environ["MINIO_ROOT_USER"],
    "secret_access_key": os.environ["MINIO_ROOT_PASSWORD"],
    "format": {"format_type": "Parquet"},
}))
')
export DEST_CONFIG

echo "Checking for existing S3/MinIO destination '${DEST_NAME}'..."
DESTINATIONS_RESPONSE=$(api_get "/destinations?workspaceIds=${WORKSPACE_ID}") || exit 1
DEST_ID=$(echo "$DESTINATIONS_RESPONSE" | python3 -c '
import json, os, sys
data = json.load(sys.stdin)["data"]
match = [d["destinationId"] for d in data if d["name"] == os.environ["DEST_NAME"]]
print(match[0] if match else "")
')

if [ -z "$DEST_ID" ]; then
  echo "Creating S3/MinIO destination at ${MINIO_REACHABLE_HOST}:${MINIO_PORT_FOR_AIRBYTE}..."
  CREATE_DEST_PAYLOAD=$(python3 -c 'import json, os; print(json.dumps({"name": os.environ["DEST_NAME"], "workspaceId": os.environ["WORKSPACE_ID"], "configuration": json.loads(os.environ["DEST_CONFIG"])}))')
  CREATE_DEST_RESPONSE=$(api_post "/destinations" "${CREATE_DEST_PAYLOAD}") || exit 1
  DEST_ID=$(echo "$CREATE_DEST_RESPONSE" | python3 -c 'import json, sys; print(json.load(sys.stdin)["destinationId"])')
else
  echo "Found existing destination ${DEST_ID}; refreshing its configuration..."
  UPDATE_DEST_PAYLOAD=$(python3 -c 'import json, os; print(json.dumps({"configuration": json.loads(os.environ["DEST_CONFIG"])}))')
  api_patch "/destinations/${DEST_ID}" "${UPDATE_DEST_PAYLOAD}" > /dev/null || exit 1
fi
echo "Destination: ${DEST_ID}"

# --- Connection (check-before-create) ---------------------------------------
export SOURCE_ID DEST_ID
echo "Checking for existing connection between source and destination..."
CONNECTIONS_RESPONSE=$(api_get "/connections?workspaceIds=${WORKSPACE_ID}") || exit 1
CONNECTION_ID=$(echo "$CONNECTIONS_RESPONSE" | python3 -c '
import json, os, sys
data = json.load(sys.stdin)["data"]
match = [c["connectionId"] for c in data if c["sourceId"] == os.environ["SOURCE_ID"] and c["destinationId"] == os.environ["DEST_ID"]]
print(match[0] if match else "")
')

if [ -z "$CONNECTION_ID" ]; then
  echo "Creating connection (full refresh | overwrite, Airbyte's auto-discovered default sync mode)..."
  CREATE_CONN_PAYLOAD=$(python3 -c 'import json, os; print(json.dumps({"sourceId": os.environ["SOURCE_ID"], "destinationId": os.environ["DEST_ID"]}))')
  CREATE_CONN_RESPONSE=$(api_post "/connections" "${CREATE_CONN_PAYLOAD}") || exit 1
  CONNECTION_ID=$(echo "$CREATE_CONN_RESPONSE" | python3 -c 'import json, sys; print(json.load(sys.stdin)["connectionId"])')
else
  echo "Found existing connection ${CONNECTION_ID}"
fi
echo "Connection: ${CONNECTION_ID}"

# --- Trigger sync and wait for completion -----------------------------------
echo "Triggering manual sync..."
export CONNECTION_ID
TRIGGER_PAYLOAD=$(python3 -c 'import json, os; print(json.dumps({"connectionId": os.environ["CONNECTION_ID"], "jobType": "sync"}))')
TRIGGER_RESPONSE=$(api_post "/jobs" "${TRIGGER_PAYLOAD}") || exit 1
JOB_ID=$(echo "$TRIGGER_RESPONSE" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("jobId", ""))')
[ -n "$JOB_ID" ] && [ "$JOB_ID" != "None" ] || { echo "ERROR: failed to trigger sync job on connection ${CONNECTION_ID}" >&2; exit 1; }
echo "Job: ${JOB_ID}"

echo "Waiting for sync job ${JOB_ID} to complete..."
STATUS="pending"
JOB="{}"
for i in $(seq 1 60); do
  JOB=$(api_get "/jobs/${JOB_ID}") || exit 1
  STATUS=$(echo "$JOB" | python3 -c 'import json, sys; print(json.load(sys.stdin)["status"])')
  echo "  [$i/60] status=${STATUS}"
  case "$STATUS" in
    succeeded)
      break
      ;;
    failed|cancelled|incomplete)
      echo "ERROR: sync job ${JOB_ID} ended with status '${STATUS}':" >&2
      echo "$JOB" >&2
      exit 1
      ;;
  esac
  sleep 10
done

if [ "$STATUS" != "succeeded" ]; then
  echo "ERROR: sync job ${JOB_ID} did not reach 'succeeded' within the timeout (last status: ${STATUS})" >&2
  exit 1
fi

ROWS=$(echo "$JOB" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("rowsSynced", "unknown"))')
echo "PASS: sync job ${JOB_ID} succeeded (${ROWS} rows synced) via connection ${CONNECTION_ID}"
