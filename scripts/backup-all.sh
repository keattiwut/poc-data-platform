#!/bin/sh
set -eu

# Daily backups (Issue 10 / ADR-0018, ~24h RPO): MinIO lake, ClickHouse
# warehouse, the Postgres cluster (Airflow metadata + pipeline + superset
# DBs), and Vault's file storage backend, into ./backups/<date>/.
#
# ./backups is the POC's stand-in for the off-host target: in production it
# is a mounted remote share / object store; the mechanism is identical.
# Runs either from the host (Git Bash/Linux) or inside the `backup` cron
# container - plain `docker exec` against fixed container names, no compose
# plugin needed. POSIX sh on purpose (the cron container is busybox).
#
# Retention: prunes date-stamped directories older than 14 days.

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env missing - run scripts/render-env-from-vault.sh"; exit 1; }
set -a; . ./.env; set +a

STAMP=$(date +%F)
DEST="backups/$STAMP"
mkdir -p "$DEST" backups/clickhouse backups/minio

echo "=== Backing up Postgres (pg_dumpall: airflow metadata + pipeline + superset) ==="
docker exec postgres pg_dumpall -U "$POSTGRES_USER" --clean > "$DEST/postgres-all.sql"
# Custom-format per-DB dump alongside the cluster dump: pg_restore can then
# restore a single database (the restore demo in verify-backups.sh uses it).
docker exec postgres pg_dump -U "$POSTGRES_USER" -Fc pipeline > "$DEST/pipeline.dump"
echo "wrote $DEST/postgres-all.sql ($(wc -c < "$DEST/postgres-all.sql") bytes) + pipeline.dump"

echo "=== Backing up ClickHouse (native BACKUP DATABASE) ==="
# Same-day re-runs are allowed: replace the day's backup file.
rm -rf "backups/clickhouse/$STAMP"
# ASYNC off (default): the query returns when the backup file is complete.
docker exec clickhouse clickhouse-client \
  --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  --query "BACKUP DATABASE default TO Disk('backups_disk', '$STAMP/default.zip')" > /dev/null
echo "wrote backups/clickhouse/$STAMP/default.zip"

echo "=== Backing up MinIO lake (mc mirror) ==="
docker exec minio mc alias set local https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null
# MSYS_NO_PATHCONV: /backups/... is an in-container path (see vault note).
MSYS_NO_PATHCONV=1 docker exec minio mc mirror --overwrite --remove local/data-lake /backups/data-lake > /dev/null
echo "mirrored data-lake -> backups/minio/data-lake"

echo "=== Backing up Vault storage backend (file backend tar) ==="
# MSYS_NO_PATHCONV: stops Git Bash rewriting the in-container paths when
# this runs on a Windows host (no-op in the cron container).
MSYS_NO_PATHCONV=1 docker exec vault tar czf - -C / vault/file > "$DEST/vault-file.tgz"
echo "wrote $DEST/vault-file.tgz ($(wc -c < "$DEST/vault-file.tgz") bytes)"

echo "=== Pruning backups older than 14 days ==="
find backups -maxdepth 1 -type d -name '20*' -mtime +14 -exec rm -rf {} + 2>/dev/null || true
find backups/clickhouse -maxdepth 1 -type d -name '20*' -mtime +14 -exec rm -rf {} + 2>/dev/null || true

echo "Backup complete: $DEST (RPO ~24h per ADR-0018)"
