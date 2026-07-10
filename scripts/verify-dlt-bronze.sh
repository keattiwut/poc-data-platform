#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# Verifies the dlt extraction tasks (Issue 04 / ADR-0024) landed Parquet in
# the bronze zone for both logical tables, across the per-channel datasets
# (bronze/<channel>/<table>/*.parquet). Replaces the Airbyte-era
# verify-airbyte-bronze-sync.sh / verify-airbyte-bank-bronze-sync.sh pair.

# See scripts/verify-postgres-minio.sh for why `mc alias set` with real
# credentials is required before `mc find` against the minio container.
docker compose exec -T minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null

for table in partner_transactions bank_transactions; do
  echo "Checking bronze-zone Parquet exists for ${table} across channel datasets..."
  FOUND=0
  for channel in partner_db bank_db sftp_drop kafka_drain; do
    # `|| true`: with pipefail, a missing channel/table path makes mc find fail
    # the whole pipeline - but "no files there" is a normal answer here.
    COUNT=$(docker compose exec -T minio mc find "local/data-lake/bronze/${channel}/${table}" --name "*.parquet" 2>/dev/null | wc -l || true)
    if [ "${COUNT:-0}" -ge 1 ]; then
      echo "  ${channel}: ${COUNT} file(s)"
      FOUND=$((FOUND + COUNT))
    fi
  done
  if [ "$FOUND" -lt 1 ]; then
    echo "FAIL: no Parquet files found under data-lake/bronze/*/${table}/"
    exit 1
  fi
  echo "PASS: found ${FOUND} Parquet file(s) for ${table}"
done

# Each logical table should arrive via more than one channel type (postgres
# always, plus sftp and/or kafka depending on the mock channel routing).
for table in partner_transactions bank_transactions; do
  CHANNELS=0
  for channel in partner_db bank_db sftp_drop kafka_drain; do
    # `|| true`: with pipefail, a missing channel/table path makes mc find fail
    # the whole pipeline - but "no files there" is a normal answer here.
    COUNT=$(docker compose exec -T minio mc find "local/data-lake/bronze/${channel}/${table}" --name "*.parquet" 2>/dev/null | wc -l || true)
    [ "${COUNT:-0}" -ge 1 ] && CHANNELS=$((CHANNELS + 1))
  done
  if [ "$CHANNELS" -lt 2 ]; then
    echo "FAIL: ${table} arrived via only ${CHANNELS} channel dataset(s); expected at least 2 (db + sftp/kafka)"
    exit 1
  fi
done
echo "PASS: both tables arrived via multiple source channels"
