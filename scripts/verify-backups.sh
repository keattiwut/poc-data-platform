#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; source .env; set +a

# Demonstrates a real RESTORE from today's backup for each backed-up system
# (Issue 10 / ADR-0018 - "backup job succeeds" is not evidence). Runs
# scripts/backup-all.sh first so it always exercises a fresh backup.

./scripts/backup-all.sh > /dev/null
STAMP=$(date +%F)
DEST="backups/$STAMP"

echo "=== 1. Postgres restore (pipeline DB -> scratch DB) ==="
LIVE=$(docker exec postgres psql -U "$POSTGRES_USER" -d pipeline -t -c "SELECT count(*) FROM partner_transactions" | tr -d ' \r')
docker exec postgres dropdb -U "$POSTGRES_USER" --if-exists restore_check
docker exec postgres createdb -U "$POSTGRES_USER" restore_check
docker exec -i postgres pg_restore -U "$POSTGRES_USER" -d restore_check --no-owner < "$DEST/pipeline.dump" 2>/dev/null || true
RESTORED=$(docker exec postgres psql -U "$POSTGRES_USER" -d restore_check -t -c "SELECT count(*) FROM partner_transactions" | tr -d ' \r')
docker exec postgres dropdb -U "$POSTGRES_USER" restore_check
[ "$RESTORED" = "$LIVE" ] || { echo "FAIL: restored $RESTORED rows, live has $LIVE"; exit 1; }
echo "PASS: pipeline DB restored into a scratch DB with all $RESTORED rows"

echo "=== 2. ClickHouse restore (dim_bank from the native backup) ==="
CH="docker exec clickhouse clickhouse-client --user $CLICKHOUSE_USER --password $CLICKHOUSE_PASSWORD"
LIVE=$($CH --query "SELECT count() FROM default.dim_bank")
$CH --query "DROP TABLE IF EXISTS default.dim_bank_restored"
$CH --query "RESTORE TABLE default.dim_bank AS default.dim_bank_restored FROM Disk('backups_disk', '$STAMP/default.zip')" > /dev/null
RESTORED=$($CH --query "SELECT count() FROM default.dim_bank_restored")
$CH --query "DROP TABLE default.dim_bank_restored"
[ "$RESTORED" = "$LIVE" ] || { echo "FAIL: restored $RESTORED rows, live has $LIVE"; exit 1; }
echo "PASS: dim_bank restored from the native backup with all $RESTORED rows"

echo "=== 3. MinIO restore (silver object round-trip from the mirror) ==="
docker exec minio mc alias set local https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null
MSYS_NO_PATHCONV=1 docker exec minio mc cp /backups/data-lake/silver/partner_transactions/data.parquet local/data-lake/restore-test/data.parquet > /dev/null
docker exec minio mc stat local/data-lake/restore-test/data.parquet > /dev/null \
  || { echo "FAIL: restored object missing"; exit 1; }
docker exec minio mc rm local/data-lake/restore-test/data.parquet > /dev/null
echo "PASS: lake object restored from the mirror back into the bucket (and cleaned up)"

echo "=== 4. Vault restore (storage backend into a scratch server, unseal, read a secret) ==="
RESTORE_DIR="backups/vault-restore-test"
rm -rf "$RESTORE_DIR"; mkdir -p "$RESTORE_DIR"
tar xzf "$DEST/vault-file.tgz" -C "$RESTORE_DIR"
cat > "$RESTORE_DIR/config.hcl" <<'EOF'
storage "file" { path = "/vault/file" }
listener "tcp" { address = "127.0.0.1:8200"  tls_disable = 1 }
EOF
docker rm -f vault-restore > /dev/null 2>&1 || true
MSYS_NO_PATHCONV=1 docker run -d --name vault-restore --cap-add IPC_LOCK \
  -v "$(pwd)/$RESTORE_DIR/vault/file:/vault/file" \
  -v "$(pwd)/$RESTORE_DIR/config.hcl:/vault/config/config.hcl:ro" \
  hashicorp/vault:1.17.6 vault server -config=/vault/config/config.hcl > /dev/null
sleep 5
UNSEAL_KEY=$(python3 -c "import json;print(json.load(open('vault/.vault-keys.json'))['keys_base64'][0])")
ROOT_TOKEN=$(python3 -c "import json;print(json.load(open('vault/.vault-keys.json'))['root_token'])")
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault-restore vault operator unseal "$UNSEAL_KEY" > /dev/null
SECRET_USER=$(docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN="$ROOT_TOKEN" vault-restore \
  vault kv get -field=user secret/postgres)
docker rm -f vault-restore > /dev/null
rm -rf "$RESTORE_DIR"
[ "$SECRET_USER" = "$POSTGRES_USER" ] || { echo "FAIL: restored Vault returned '$SECRET_USER'"; exit 1; }
echo "PASS: restored Vault unsealed with the saved key and served the postgres secret"

echo "PASS: all four systems restored successfully from today's backups"
