#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# Verifies the Issue 07 data-quality layer end to end:
#   1. dbt tests + source freshness pass on clean pipeline output
#   2. the tests actually CATCH a real generator-injected anomaly: re-promote
#      bronze->silver with the dedup disabled (PROMOTE_SKIP_DEDUP=1), letting
#      the mock generator's duplicate Transaction IDs (MOCK_DUPLICATE_RATE,
#      Issue 05) through to silver, and confirm the unique test fails
#   3. restore silver with a normal promotion and confirm tests pass again
#
# This is the honest shape of the demo: the generator's duplicates are real
# and always present in bronze; the promotion dedup is the defense; the dbt
# unique test is the alarm that fires if that defense regresses.

DBT="docker compose exec -T airflow-scheduler bash -c"
DBT_DIR="/opt/airflow/dbt/payment_gateway"
# MSYS_NO_PATHCONV stops Git Bash mangling the in-container /opt/... path
# into a Windows path; harmless no-op elsewhere.
PROMOTE="env MSYS_NO_PATHCONV=1 docker compose exec -T"

echo "=== 1/3: dbt tests + source freshness on clean data ==="
$DBT "cd ${DBT_DIR} && DBT_PROFILES_DIR=. dbt test" > /dev/null \
  || { echo "FAIL: dbt tests failed on clean pipeline output"; exit 1; }
echo "PASS: all dbt tests pass on clean data"
$DBT "cd ${DBT_DIR} && DBT_PROFILES_DIR=. dbt source freshness" > /dev/null \
  || { echo "FAIL: dbt source freshness breached on a fresh pipeline run"; exit 1; }
echo "PASS: source freshness within SLA thresholds"

echo "=== 2/3: proving the unique test catches the generator's duplicate IDs ==="
$PROMOTE -e PROMOTE_SKIP_DEDUP=1 airflow-scheduler \
  python /opt/airflow/scripts/promote-bronze-to-silver.py partner_transactions
DQ_OUTPUT=$($DBT "cd ${DBT_DIR} && DBT_PROFILES_DIR=. dbt test --select stg_partner_transactions" 2>&1 || true)
if ! echo "$DQ_OUTPUT" | grep -q "FAIL.*unique_stg_partner_transactions_transaction_id"; then
  echo "FAIL: expected unique_stg_partner_transactions_transaction_id to fail against undeduped silver"
  echo "$DQ_OUTPUT" | tail -20
  exit 1
fi
echo "PASS: unique test failed as expected against the injected duplicate Transaction IDs"

echo "=== 3/3: restoring silver and re-running tests ==="
$PROMOTE airflow-scheduler \
  python /opt/airflow/scripts/promote-bronze-to-silver.py partner_transactions
$DBT "cd ${DBT_DIR} && DBT_PROFILES_DIR=. dbt test --select stg_partner_transactions" > /dev/null \
  || { echo "FAIL: dbt tests still failing after restoring the deduped silver"; exit 1; }
echo "PASS: tests green again after normal promotion"

echo "PASS: data-quality tests verified - clean data passes, injected anomaly caught, restore clean"
