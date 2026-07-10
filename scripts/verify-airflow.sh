#!/usr/bin/env bash
set -euo pipefail

# Airflow 3: the webserver became the api-server and the health endpoint
# moved from /health to /api/v2/monitor/health (unauthenticated). The payload
# also reports the (new, mandatory) dag-processor component.
HEALTH_URL="http://localhost:8080/api/v2/monitor/health"

echo "Checking Airflow api-server health endpoint..."
curl -sf "$HEALTH_URL" > /dev/null

echo "Checking Airflow scheduler is reported healthy..."
curl -sf "$HEALTH_URL" | jq -e '.scheduler.status == "healthy"' > /dev/null \
  || (echo "FAIL: scheduler not healthy" && exit 1)

echo "Checking Airflow dag-processor is reported healthy..."
curl -sf "$HEALTH_URL" | jq -e '.dag_processor.status == "healthy"' > /dev/null \
  || (echo "FAIL: dag-processor not healthy" && exit 1)

echo "PASS: Airflow api-server, scheduler and dag-processor are healthy"
