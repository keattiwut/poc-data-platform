#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking silver-zone Parquet exists for partner_transactions..."
# See scripts/verify-postgres-minio.sh for why `mc alias set` with real
# credentials is required before `mc find`/`mc ls` against the minio
# container's own `mc` binary.
docker compose exec -T minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null
COUNT=$(docker compose exec -T minio mc find local/data-lake/silver/partner_transactions --name "*.parquet" 2>/dev/null | wc -l)
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no Parquet files found under data-lake/silver/partner_transactions/"
  exit 1
fi

echo "PASS: found ${COUNT} Parquet file(s) in silver/partner_transactions"
