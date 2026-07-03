# Sourced, not executed directly. Logs into Superset's API and exports
# SUPERSET_ACCESS_TOKEN for subsequent authenticated requests.
SUPERSET_ACCESS_TOKEN=$(curl -sf -X POST "http://localhost:8088/api/v1/security/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${SUPERSET_ADMIN_USER}\", \"password\": \"${SUPERSET_ADMIN_PASSWORD}\", \"provider\": \"db\", \"refresh\": true}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
export SUPERSET_ACCESS_TOKEN
