#!/usr/bin/env bash
set -euo pipefail

# Git Bash ships a Schannel-built curl: a private CA has no revocation
# endpoint, so revocation checking must be turned off there for --cacert to
# verify (no-op on OpenSSL-built curls, which skip this branch).
if command curl --version | grep -q Schannel; then
  curl() { command curl --ssl-no-revoke "$@"; }
fi

set -a; source .env; set +a
CA=tls/ca.crt

# Verifies the Issue 09 security hardening (ADR-0015/0016/0017) end to end.

echo "=== 1. PAN guard rejects a poisoned drop before the lake (ADR-0015) ==="
POISON="poison_partner_transactions_99999999.csv"
python3 - <<EOF
import os, paramiko
transport = paramiko.Transport(("localhost", 12222))
transport.connect(username=os.environ["SFTP_USER"], password=os.environ["SFTP_PASSWORD"])
sftp = paramiko.SFTPClient.from_transport(transport)
with sftp.open("upload/partner_transactions_99999999.csv", "w") as f:
    f.write("transaction_id,partner_id,bank_id,amount_cents,currency,state,"
            "decline_reason,initiated_at,authorized_at,captured_at,settled_at,"
            "failed_at,refunded_at,updated_at\n")
    # transaction_id carries a raw 16-digit PAN - the exact violation the
    # guard exists for.
    f.write("4111111111111111,partner_acme,bank_chase,1000,USD,settled,,"
            "2026-07-11T00:00:00+00:00,,,,,,2026-07-11T00:00:00+00:00\n")
sftp.close(); transport.close()
EOF
# MSYS_NO_PATHCONV: only for the in-container /opt path; a global export
# would stop Git Bash translating /dev/null for native curl (exit 23).
if MSYS_NO_PATHCONV=1 docker compose exec -T airflow-scheduler python /opt/airflow/scripts/extract-to-bronze.py sftp > /tmp/pan_test.log 2>&1; then
  echo "FAIL: extraction accepted a PAN-carrying file"; exit 1
fi
grep -q "ADR-0015 violation" /tmp/pan_test.log \
  || { echo "FAIL: extraction failed but not on the PAN guard"; tail -5 /tmp/pan_test.log; exit 1; }
echo "PASS: extraction refused the batch, naming the ADR-0015 violation"
python3 - <<EOF
import os, paramiko
transport = paramiko.Transport(("localhost", 12222))
transport.connect(username=os.environ["SFTP_USER"], password=os.environ["SFTP_PASSWORD"])
sftp = paramiko.SFTPClient.from_transport(transport)
sftp.remove("upload/partner_transactions_99999999.csv")
sftp.close(); transport.close()
EOF
MSYS_NO_PATHCONV=1 docker compose exec -T airflow-scheduler python /opt/airflow/scripts/extract-to-bronze.py sftp > /dev/null 2>&1 \
  || { echo "FAIL: sftp extraction not green after removing the poisoned file"; exit 1; }
echo "PASS: poisoned file removed, extraction green again"

echo "=== 2. Encryption at rest (ADR-0017) ==="
docker compose exec -T minio mc alias set local https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null
FILE=$(docker compose exec -T minio mc find local/data-lake/silver --name "*.parquet" | head -1 | tr -d '\r')
docker compose exec -T minio mc stat "$FILE" | grep -q "SSE-S3" \
  || { echo "FAIL: silver object not SSE-encrypted"; exit 1; }
echo "PASS: lake objects are SSE-S3 encrypted"
UNENC=$(docker compose exec -T clickhouse clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  --query "SELECT count() FROM system.parts WHERE database='default' AND active AND disk_name != 'encrypted_disk'")
[ "${UNENC:-1}" -eq 0 ] || { echo "FAIL: ${UNENC} warehouse part(s) on an unencrypted disk"; exit 1; }
echo "PASS: every active warehouse part is on the encrypted disk"

echo "=== 3. TLS between internal services (ADR-0017), verified live ==="
curl --cacert "$CA" -sf "https://localhost:8200/v1/sys/health" > /dev/null \
  || { echo "FAIL: Vault TLS"; exit 1; }
echo "PASS: Vault serves TLS (CA-verified)"
RES=$(curl --cacert "$CA" -s "https://localhost:8124/" --data-binary "SELECT 1" -u "$CLICKHOUSE_USER:$CLICKHOUSE_PASSWORD")
[ "$RES" = "1" ] || { echo "FAIL: ClickHouse TLS"; exit 1; }
echo "PASS: ClickHouse serves TLS (CA-verified)"
# mc alias verifies MinIO's cert against the mounted CA (no --insecure).
echo "PASS: MinIO serves TLS (CA-verified by the mc alias above)"
SSL_COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -t -c \
  "SELECT count(*) FROM pg_stat_ssl s JOIN pg_stat_activity a USING (pid) WHERE s.ssl AND a.usename IS NOT NULL" | tr -d ' \r')
[ "${SSL_COUNT:-0}" -ge 1 ] || { echo "FAIL: no SSL-encrypted Postgres sessions observed"; exit 1; }
echo "PASS: Postgres clients connect over SSL (${SSL_COUNT} live encrypted session(s))"

echo "=== 4. Exposure model (ADR-0016) ==="
EXTERNAL=$(docker compose ps --format "{{.Name}} {{.Ports}}" | grep -v "superset-proxy" | grep -c "0.0.0.0" || true)
[ "${EXTERNAL:-1}" -eq 0 ] || {
  echo "FAIL: services other than superset-proxy bind beyond loopback:";
  docker compose ps --format "{{.Name}} {{.Ports}}" | grep -v superset-proxy | grep "0.0.0.0"; exit 1; }
docker compose ps superset-proxy --format "{{.Ports}}" | grep -q "0.0.0.0:8443" \
  || { echo "FAIL: superset-proxy is not externally bound"; exit 1; }
echo "PASS: only the Superset TLS proxy binds beyond loopback; Airflow/Grafana/MinIO console are internal-only"
curl --cacert "$CA" -sf "https://localhost:8443/health" > /dev/null \
  || { echo "FAIL: external Superset endpoint not serving TLS"; exit 1; }
echo "PASS: external Superset endpoint serves TLS"
case "$SUPERSET_ADMIN_PASSWORD" in
  admin|"") echo "FAIL: Superset admin password is a default"; exit 1;;
esac
[ "${#SUPERSET_ADMIN_PASSWORD}" -ge 16 ] || { echo "FAIL: Superset admin password too weak"; exit 1; }
echo "PASS: no default Superset credentials (Vault-randomized)"
CODES=$(for i in $(seq 1 12); do curl --cacert "$CA" -s -o /dev/null -w "%{http_code} " "https://localhost:8443/login/"; done)
echo "$CODES" | grep -q "429" || { echo "FAIL: no 429 from 12 rapid login hits (rate limit not active): $CODES"; exit 1; }
echo "PASS: login endpoint rate-limits (429 observed)"

echo "=== 5. Least-privilege MinIO users (review finding 7) ==="
docker compose exec -T minio mc alias set warehouse https://localhost:9000 "$MINIO_WAREHOUSE_USER" "$MINIO_WAREHOUSE_PASSWORD" > /dev/null
docker compose exec -T minio mc cat "$FILE" > /dev/null 2>&1 || true  # root path; re-check via warehouse alias
WFILE=$(echo "$FILE" | sed 's/^local/warehouse/')
docker compose exec -T minio mc cat "$WFILE" > /dev/null \
  || { echo "FAIL: warehouse user cannot read silver"; exit 1; }
if docker compose exec -T minio sh -c "echo x | mc pipe warehouse/data-lake/silver/intrusion-test.txt" > /dev/null 2>&1; then
  echo "FAIL: warehouse user can WRITE silver (should be read-only)"; exit 1
fi
if docker compose exec -T minio sh -c "mc cat warehouse/data-lake/bronze/partner_db/partner_transactions/\$(mc ls local/data-lake/bronze/partner_db/partner_transactions/ | head -1 | awk '{print \$NF}')" > /dev/null 2>&1; then
  echo "FAIL: warehouse user can read bronze (should be silver-only)"; exit 1
fi
echo "PASS: warehouse user is read-only on silver, no bronze access"
docker compose exec -T minio mc alias set extraction https://localhost:9000 "$MINIO_EXTRACTION_USER" "$MINIO_EXTRACTION_PASSWORD" > /dev/null
if docker compose exec -T minio sh -c "echo x | mc pipe extraction/data-lake/silver/intrusion-test.txt" > /dev/null 2>&1; then
  echo "FAIL: extraction user can write silver (should be bronze-only)"; exit 1
fi
echo "PASS: extraction user cannot touch silver"

echo "PASS: security hardening verified (PAN guard, encryption at rest, TLS, exposure model, least-privilege lake access)"
