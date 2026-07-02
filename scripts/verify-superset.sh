#!/usr/bin/env bash
set -euo pipefail

echo "Checking Superset health endpoint..."
RESULT=$(curl -sf http://localhost:8088/health)
if [ "$RESULT" != "OK" ]; then
  echo "FAIL: expected 'OK', got '${RESULT}'"
  exit 1
fi

echo "PASS: Superset is healthy"
