#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking stg_partner_transactions has rows in ClickHouse..."
COUNT=$(curl -sf "http://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@localhost:8124/?query=SELECT%20count(*)%20FROM%20stg_partner_transactions")
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: stg_partner_transactions has no rows (found: ${COUNT:-0})"
  exit 1
fi

echo "PASS: stg_partner_transactions has ${COUNT} rows"
