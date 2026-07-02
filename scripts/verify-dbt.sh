#!/usr/bin/env bash
set -euo pipefail

# .env has plain KEY=VALUE lines (no `export`), so a plain `source .env` only
# sets shell variables in this process — it does not mark them for export, so
# the `dbt` invocation below (which reads CLICKHOUSE_USER/CLICKHOUSE_PASSWORD
# via profiles.yml's env_var()) would not inherit them. Use `set -a` so every
# variable sourced from .env is exported, and so this script is self-contained
# and works standalone rather than depending on the caller having exported
# these first. Same pattern used in scripts/verify-clickhouse.sh and
# scripts/verify-postgres-minio.sh.
set -a
source .env
set +a

echo "Checking dbt can connect to ClickHouse..."
cd dbt/payment_gateway
DBT_PROFILES_DIR=. dbt debug | tee /tmp/dbt-debug-output.txt
grep -q "All checks passed!" /tmp/dbt-debug-output.txt \
  || (echo "FAIL: dbt debug did not report all checks passed" && exit 1)

echo "PASS: dbt is configured and connects to ClickHouse"
