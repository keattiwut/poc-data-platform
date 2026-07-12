#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; source .env; set +a

# Demonstrates fail-loud schema drift (Issue 10 / ADR-0019): a mock source
# adds a column -> the dlt schema contract fails the extraction task inside
# daily_pipeline -> the Issue-08 failure callback posts to the CRITICAL
# Teams channel. Then removes the drift and shows the pipeline green again.

DAG_TRIGGER="docker compose exec -T airflow-scheduler airflow dags trigger daily_pipeline"
LAST_STATE='docker compose exec -T airflow-scheduler airflow dags list-runs daily_pipeline'

echo "=== Dropping a schema-drifted file (new column 'surprise_risk_score') ==="
python3 - <<'EOF'
import os, paramiko
t = paramiko.Transport(("localhost", 12222))
t.connect(username=os.environ["SFTP_USER"], password=os.environ["SFTP_PASSWORD"])
sftp = paramiko.SFTPClient.from_transport(t)
with sftp.open("upload/partner_transactions_99999997.csv", "w") as f:
    f.write("transaction_id,partner_id,bank_id,amount_cents,currency,state,decline_reason,"
            "initiated_at,authorized_at,captured_at,settled_at,failed_at,refunded_at,"
            "updated_at,surprise_risk_score\n")
    f.write("drift-demo-0001,partner_acme,bank_chase,1000,USD,settled,,"
            "2026-07-12T00:00:00+00:00,,,,,,2026-07-12T00:00:00+00:00,0.97\n")
sftp.close(); t.close()
EOF

curl -sf -X DELETE "http://localhost:18080/messages" > /dev/null
$DAG_TRIGGER > /dev/null 2>&1
echo "daily_pipeline triggered; waiting for extract_sftp to fail on the contract..."

ALERTED=0
for i in $(seq 1 40); do
  HIT=$(curl -sf "http://localhost:18080/messages" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)['critical']
hits = [m for m in msgs if 'extract_sftp' in json.dumps(m) and 'runbooks/' in json.dumps(m)]
print(len(hits))" 2>/dev/null || echo 0)
  if [ "${HIT:-0}" -ge 1 ]; then ALERTED=1; break; fi
  sleep 15
done
[ "$ALERTED" -eq 1 ] || { echo "FAIL: no Critical alert for the drifted extract_sftp task"; exit 1; }
echo "PASS: schema drift failed extract_sftp and produced a Critical Teams alert with a runbook link"

echo "=== Removing the drift and confirming the pipeline recovers ==="
python3 - <<'EOF'
import os, paramiko
t = paramiko.Transport(("localhost", 12222))
t.connect(username=os.environ["SFTP_USER"], password=os.environ["SFTP_PASSWORD"])
sftp = paramiko.SFTPClient.from_transport(t)
sftp.remove("upload/partner_transactions_99999997.csv")
sftp.close(); t.close()
EOF
# wait out the failing run before re-triggering (max_active_runs=1)
for i in $(seq 1 40); do
  STATE=$($LAST_STATE 2>/dev/null | grep "manual__" | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  case "$STATE" in success|failed) break;; esac
  sleep 15
done
$DAG_TRIGGER > /dev/null 2>&1
for i in $(seq 1 40); do
  STATE=$($LAST_STATE 2>/dev/null | grep "manual__" | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')
  case "$STATE" in success|failed) break;; esac
  sleep 20
done
[ "$STATE" = "success" ] || { echo "FAIL: pipeline did not recover after removing the drift (state=$STATE)"; exit 1; }
echo "PASS: pipeline green again after the drift was reviewed and removed"

echo "PASS: schema drift fails loudly, routes to Critical, and never propagates silently"
