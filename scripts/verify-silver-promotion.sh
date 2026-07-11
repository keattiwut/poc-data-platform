#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# See scripts/verify-postgres-minio.sh for why `mc alias set` with real
# credentials is required before `mc find`/`mc ls` against the minio
# container's own `mc` binary.
docker compose exec -T minio mc alias set local https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null

check_table() {
  local table="$1"
  echo "Checking silver-zone Parquet exists for ${table}..."
  local count
  count=$(docker compose exec -T minio mc find "local/data-lake/silver/${table}" --name "*.parquet" 2>/dev/null | wc -l)
  if [ "${count:-0}" -lt 1 ]; then
    echo "FAIL: no Parquet files found under data-lake/silver/${table}/"
    exit 1
  fi
  echo "PASS: found ${count} Parquet file(s) in silver/${table}"
}

if [ $# -ge 1 ]; then
  check_table "$1"
else
  check_table "partner_transactions"
  check_table "bank_transactions"
fi
