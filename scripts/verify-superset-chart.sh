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
CHART_COUNT=$(curl -sf -H "Authorization: Bearer ${SUPERSET_ACCESS_TOKEN}" \
  -G --data-urlencode "q=(filters:!((col:slice_name,opr:eq,value:'Transaction Volume by Day')))" \
  "http://localhost:8088/api/v1/chart/" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")

if [ "${CHART_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no chart named 'Transaction Volume by Day' found"
  exit 1
fi

echo "PASS: found the Transaction Volume by Day chart in Superset"
