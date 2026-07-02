#!/usr/bin/env bash
set -euo pipefail

echo "Checking Airflow webserver health endpoint..."
curl -sf http://localhost:8080/health > /dev/null

echo "Checking Airflow scheduler is reported healthy..."
curl -sf http://localhost:8080/health | jq -e '.scheduler.status == "healthy"' > /dev/null \
  || (echo "FAIL: scheduler not healthy" && exit 1)

echo "PASS: Airflow webserver and scheduler are healthy"
