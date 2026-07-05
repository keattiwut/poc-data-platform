#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# .env stores SFTP_HOST="sftp" and KAFKA_BOOTSTRAP_SERVERS="kafka:9092" - the
# Docker Compose service name/port, resolvable only *inside* the Compose
# network. This script runs on the host, so override to the host-mapped
# address for this one invocation only (same pattern as
# scripts/verify-sftp-kafka-infra.sh); .env itself is left untouched.
SFTP_HOST=localhost
KAFKA_BOOTSTRAP_SERVERS="localhost:9094"

echo "Checking SFTP upload/ has partner and bank CSV files..."
SFTP_COUNTS=$(python3 -c "
import os, paramiko
transport = paramiko.Transport((os.environ['SFTP_HOST'], int(os.environ['SFTP_PORT'])))
transport.connect(username=os.environ['SFTP_USER'], password=os.environ['SFTP_PASSWORD'])
sftp = paramiko.SFTPClient.from_transport(transport)
files = sftp.listdir('upload')
sftp.close()
transport.close()
partner_files = [f for f in files if f.startswith('partner_transactions_')]
bank_files = [f for f in files if f.startswith('bank_transactions_')]
print(f'{len(partner_files)} {len(bank_files)}')
")
PARTNER_FILE_COUNT=$(echo "$SFTP_COUNTS" | cut -d' ' -f1)
BANK_FILE_COUNT=$(echo "$SFTP_COUNTS" | cut -d' ' -f2)
if [ "${PARTNER_FILE_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no partner_transactions_*.csv files found on SFTP (found ${PARTNER_FILE_COUNT:-0})"
  exit 1
fi
if [ "${BANK_FILE_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no bank_transactions_*.csv files found on SFTP (found ${BANK_FILE_COUNT:-0})"
  exit 1
fi
echo "PASS: found ${PARTNER_FILE_COUNT} partner CSV file(s) and ${BANK_FILE_COUNT} bank CSV file(s) on SFTP"

echo "Checking Kafka topics 'partner-transactions' and 'bank-transactions' have messages..."
KAFKA_COUNTS=$(python3 -c "
import os
from kafka import KafkaConsumer
counts = {}
for topic in ('partner-transactions', 'bank-transactions'):
    consumer = KafkaConsumer(
        topic,
        bootstrap_servers=os.environ['KAFKA_BOOTSTRAP_SERVERS'],
        auto_offset_reset='earliest',
        consumer_timeout_ms=10000,
    )
    counts[topic] = sum(1 for _ in consumer)
    consumer.close()
print(f\"{counts['partner-transactions']} {counts['bank-transactions']}\")
")
PARTNER_MSG_COUNT=$(echo "$KAFKA_COUNTS" | cut -d' ' -f1)
BANK_MSG_COUNT=$(echo "$KAFKA_COUNTS" | cut -d' ' -f2)
if [ "${PARTNER_MSG_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no messages found in Kafka topic 'partner-transactions' (found ${PARTNER_MSG_COUNT:-0})"
  exit 1
fi
if [ "${BANK_MSG_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no messages found in Kafka topic 'bank-transactions' (found ${BANK_MSG_COUNT:-0})"
  exit 1
fi
echo "PASS: found ${PARTNER_MSG_COUNT} partner message(s) and ${BANK_MSG_COUNT} bank message(s) in Kafka"
