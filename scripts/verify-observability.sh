#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# Verifies the Issue 08 observability stack end to end:
#   1. Prometheus scrapes ClickHouse, MinIO, and Airflow (via statsd-exporter)
#   2. Loki holds logs from the pipeline services
#   3. Grafana is up with both datasources and the provisioned dashboard
#   4. LIVE FAILURE DEMO: stop ClickHouse -> the ClickHouseUnreachable rule
#      fires -> Alertmanager routes it to the CRITICAL Teams channel with a
#      runbook link (mock-teams receiver) -> restart ClickHouse
# The Airflow-callback path into the same channels is exercised separately
# (fail a task while ClickHouse is down and the callback posts critical).

echo "=== Prometheus targets ==="
for job in clickhouse minio airflow; do
  HEALTH=$(curl -sf "http://localhost:9090/api/v1/targets" | python3 -c "
import sys, json
targets = json.load(sys.stdin)['data']['activeTargets']
print(next((t['health'] for t in targets if t['labels']['job'] == '$job'), 'missing'))")
  if [ "$HEALTH" != "up" ]; then
    echo "FAIL: prometheus target '$job' is '$HEALTH', expected 'up'"
    exit 1
  fi
  echo "PASS: prometheus scrapes '$job'"
done

echo "=== Loki log aggregation ==="
STREAMS=$(curl -sf -G "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query=count_over_time({container="clickhouse"}[15m])' \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']['result']))")
if [ "${STREAMS:-0}" -lt 1 ]; then
  echo "FAIL: Loki has no recent logs for container=clickhouse"
  exit 1
fi
echo "PASS: Loki aggregates container logs (clickhouse stream present)"

echo "=== Grafana health, datasources, dashboard ==="
curl -sf "http://localhost:3000/api/health" > /dev/null || { echo "FAIL: Grafana unreachable"; exit 1; }
DS=$(curl -sf -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" "http://localhost:3000/api/datasources" \
  | python3 -c "import sys,json; print(sorted(d['type'] for d in json.load(sys.stdin)))")
echo "$DS" | grep -q "loki" && echo "$DS" | grep -q "prometheus" \
  || { echo "FAIL: Grafana datasources missing (found $DS)"; exit 1; }
curl -sf -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  "http://localhost:3000/api/dashboards/uid/infra-health" > /dev/null \
  || { echo "FAIL: provisioned dashboard 'infra-health' not found"; exit 1; }
echo "PASS: Grafana up with Prometheus + Loki datasources and the Infra Health dashboard"

echo "=== LIVE FAILURE DEMO: ClickHouse down -> Critical Teams alert ==="
curl -sf -X DELETE "http://localhost:18080/messages" > /dev/null
docker compose stop clickhouse > /dev/null 2>&1
echo "ClickHouse stopped; waiting for ClickHouseUnreachable to fire and route (scrape 15s + for 1m + group_wait)..."
ALERTED=0
for i in $(seq 1 30); do
  COUNT=$(curl -sf "http://localhost:18080/messages" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)['critical']
hits = [m for m in msgs if 'ClickHouse' in json.dumps(m) and 'runbooks/clickhouse-unreachable.md' in json.dumps(m)]
print(len(hits))")
  if [ "${COUNT:-0}" -ge 1 ]; then ALERTED=1; break; fi
  sleep 10
done
docker compose up -d clickhouse > /dev/null 2>&1
if [ "$ALERTED" -ne 1 ]; then
  echo "FAIL: no Critical Teams alert with the clickhouse-unreachable runbook link arrived within 5 minutes"
  exit 1
fi
echo "PASS: Critical channel received the ClickHouseUnreachable alert with its runbook link"

echo "Waiting for ClickHouse to come back healthy..."
for i in $(seq 1 30); do
  docker compose ps clickhouse | grep -q "healthy" && break
  sleep 5
done
docker compose ps clickhouse | grep -q "healthy" || { echo "FAIL: ClickHouse did not recover"; exit 1; }
echo "PASS: ClickHouse recovered"

echo "PASS: observability stack verified (metrics, logs, dashboards, severity-routed alerting with runbook links)"
