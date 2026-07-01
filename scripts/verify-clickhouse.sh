#!/usr/bin/env bash
set -euo pipefail

# .env has plain KEY=VALUE lines (no `export`), so a caller's `source .env`
# only sets shell variables in the caller's shell — they are not inherited by
# this script, which runs as a separate process. Re-source with `set -a` here
# so CLICKHOUSE_PASSWORD is actually exported into this process's environment.
# Same pattern used in scripts/verify-postgres-minio.sh.
set -a
source .env
set +a

echo "Checking ClickHouse HTTP interface..."
RESULT=$(curl -sf "http://pipeline_ch_admin:${CLICKHOUSE_PASSWORD}@localhost:8123/?query=SELECT%201")
if [ "$RESULT" != "1" ]; then
  echo "FAIL: expected '1', got '${RESULT}'"
  exit 1
fi

echo "PASS: ClickHouse is up and query-able"
