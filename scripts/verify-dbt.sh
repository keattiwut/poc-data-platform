#!/usr/bin/env bash
set -euo pipefail

echo "Checking dbt can connect to ClickHouse..."
cd dbt/payment_gateway
DBT_PROFILES_DIR=. dbt debug | tee /tmp/dbt-debug-output.txt
grep -q "All checks passed!" /tmp/dbt-debug-output.txt \
  || (echo "FAIL: dbt debug did not report all checks passed" && exit 1)

echo "PASS: dbt is configured and connects to ClickHouse"
