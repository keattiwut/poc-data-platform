#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Prints the operator access card: every UI/endpoint with its live
# credentials from the Vault-rendered .env. LOCAL USE ONLY - this prints
# secrets to your terminal; never pipe it into logs, tickets, or chat.

[ -f .env ] || { echo "ERROR: .env missing - run ./scripts/render-env-from-vault.sh first"; exit 1; }
set -a; source .env; set +a

ROOT_TOKEN=$(python3 -c "import json;print(json.load(open('vault/.vault-keys.json'))['root_token'])" 2>/dev/null || echo "<vault/.vault-keys.json missing>")

cat <<EOF
================= ACCESS CARD (local secrets - do not share) =================

Business dashboard (Superset)
  external : https://<host>:8443          (self-signed cert - accept warning)
  internal : http://localhost:8088
  login    : ${SUPERSET_ADMIN_USER} / ${SUPERSET_ADMIN_PASSWORD}

Airflow UI (DAGs, task logs, triggers)
  url      : http://localhost:8080
  login    : ${AIRFLOW_ADMIN_USER} / ${AIRFLOW_ADMIN_PASSWORD}

Grafana (infra health + logs)
  url      : http://localhost:3000
  login    : ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD}

MinIO console (lake browser)
  url      : http://localhost:9001
  login    : ${MINIO_ROOT_USER} / ${MINIO_ROOT_PASSWORD}
  service users (S3 API, least-privilege):
    extraction : ${MINIO_EXTRACTION_USER} / ${MINIO_EXTRACTION_PASSWORD}   (rw bronze/)
    promotion  : ${MINIO_PROMOTION_USER} / ${MINIO_PROMOTION_PASSWORD}   (ro bronze, rw silver)
    warehouse  : ${MINIO_WAREHOUSE_USER} / ${MINIO_WAREHOUSE_PASSWORD}   (ro silver)

Vault (UI + API)
  url      : https://localhost:8200        (CA: tls/ca.crt)
  token    : ${ROOT_TOKEN}

ClickHouse (SQL over HTTPS)
  url      : https://localhost:8124        (CA: tls/ca.crt)
  login    : ${CLICKHOUSE_USER} / ${CLICKHOUSE_PASSWORD}
  try      : curl --cacert tls/ca.crt -u '${CLICKHOUSE_USER}:<password>' \\
               https://localhost:8124/ --data 'SELECT count() FROM mart_transactions'

Postgres (mock source + metadata DBs: pipeline / airflow / superset)
  host     : localhost:5432 (sslmode required by clients)
  login    : ${POSTGRES_USER} / ${POSTGRES_PASSWORD}

Mock SFTP (drop/browse source files)
  host     : localhost:12222   dir: upload/
  login    : ${SFTP_USER} / ${SFTP_PASSWORD}

Mock Kafka (source topics: partner-transactions, bank-transactions)
  broker   : 127.0.0.1:9094 (PLAINTEXT; use 127.0.0.1, not localhost)

No login needed: Prometheus :9090 - Alertmanager :9093 - Loki :3100
Mock Teams channels: http://localhost:18080/messages

===============================================================================
EOF
