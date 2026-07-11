#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# Smoke test for the dlt Kafka drain (Issue 04): the kafka_consumer verified
# source was the thinnest square in the ADR-0024 evidence matrix, so it gets
# its own test. Runs the extraction inside the airflow-scheduler container
# (the same environment the DAG task uses), then asserts (1) bronze Parquet
# exists for both topics and (2) the drain is incremental - a second run with
# no new messages loads nothing new.
#
# Prerequisite: mock/generate_transactions.py has produced Kafka messages
# (scripts/verify-sftp-kafka-generated.sh checks that).

# MSYS_NO_PATHCONV stops Git Bash mangling the in-container /opt/... path
# into a Windows path; harmless no-op elsewhere.
EXTRACT="env MSYS_NO_PATHCONV=1 docker compose exec -T airflow-scheduler python /opt/airflow/scripts/extract-to-bronze.py kafka"

count_bronze_parquet() {
  docker compose exec -T minio mc find "local/data-lake/bronze/kafka_drain/$1" --name "*.parquet" 2>/dev/null | wc -l || true
}

echo "Running dlt Kafka drain (first pass)..."
$EXTRACT

# See scripts/verify-postgres-minio.sh for why `mc alias set` with real
# credentials is required before `mc find` against the minio container.
docker compose exec -T minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" > /dev/null

PARTNER_COUNT=$(count_bronze_parquet partner_transactions)
BANK_COUNT=$(count_bronze_parquet bank_transactions)
if [ "${PARTNER_COUNT:-0}" -lt 1 ] || [ "${BANK_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: expected Parquet in bronze/kafka_drain for both topics (partner=${PARTNER_COUNT:-0}, bank=${BANK_COUNT:-0})"
  exit 1
fi
echo "PASS: drained Kafka to bronze (partner=${PARTNER_COUNT} file(s), bank=${BANK_COUNT} file(s))"

echo "Running dlt Kafka drain again (offset tracking: expect no new files)..."
$EXTRACT
PARTNER_COUNT_2=$(count_bronze_parquet partner_transactions)
BANK_COUNT_2=$(count_bronze_parquet bank_transactions)
if [ "$PARTNER_COUNT_2" != "$PARTNER_COUNT" ] || [ "$BANK_COUNT_2" != "$BANK_COUNT" ]; then
  echo "FAIL: second drain with no new messages wrote new files (partner ${PARTNER_COUNT}->${PARTNER_COUNT_2}, bank ${BANK_COUNT}->${BANK_COUNT_2}) - offset tracking is not working"
  exit 1
fi
echo "PASS: second drain loaded nothing new - offsets are tracked"
