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
# Host-side port is 8124, not ClickHouse's default 8123: on this dev machine,
# 8123 is taken by a pre-existing socksproxy.exe Windows service. See
# docker-compose.yml's clickhouse service ports mapping.
RESULT=$(curl -sf "http://pipeline_ch_admin:${CLICKHOUSE_PASSWORD}@localhost:8124/?query=SELECT%201")
if [ "$RESULT" != "1" ]; then
  echo "FAIL: expected '1', got '${RESULT}'"
  exit 1
fi

echo "PASS: ClickHouse is up and query-able"
