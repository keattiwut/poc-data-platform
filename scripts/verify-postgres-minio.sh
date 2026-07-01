#!/usr/bin/env bash
set -euo pipefail

echo "Checking PostgreSQL is reachable..."
docker compose exec -T postgres pg_isready -U pipeline_admin > /dev/null

echo "Checking MinIO is reachable..."
curl -sf http://localhost:9000/minio/health/live > /dev/null

echo "Checking data-lake bucket exists..."
# NOTE: the minio image ships its own `mc` binary with a built-in "local" alias
# that points at localhost:9000 with empty credentials. That alias lives in the
# minio container's own filesystem (separate from the minio-init container that
# actually created the bucket), so it must be (re)configured with real
# credentials here before it can list the bucket.
set -a
source .env
set +a
docker compose exec -T minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null
docker compose exec -T minio mc ls local/data-lake > /dev/null

echo "PASS: PostgreSQL and MinIO are up, data-lake bucket exists"
