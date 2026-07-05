#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# .env stores SFTP_HOST="sftp" and KAFKA_BOOTSTRAP_SERVERS="kafka:9092" - the
# Docker Compose service name/port, resolvable only *inside* the Compose
# network (used by in-network consumers like Airbyte's source config, same
# pattern as POSTGRES_HOST - see scripts/verify-walking-skeleton.sh). This
# script runs on the host, so override to the host-mapped address for this
# one invocation only; .env itself is left untouched.
SFTP_HOST=localhost
KAFKA_BOOTSTRAP_SERVERS="localhost:9094"

echo "Checking SFTP server is reachable and accepts login..."
python3 -c "
import os, paramiko, sys
transport = paramiko.Transport((os.environ['SFTP_HOST'], int(os.environ['SFTP_PORT'])))
try:
    transport.connect(username=os.environ['SFTP_USER'], password=os.environ['SFTP_PASSWORD'])
    sftp = paramiko.SFTPClient.from_transport(transport)
    sftp.listdir('upload')
    sftp.close()
finally:
    transport.close()
print('SFTP login and upload/ directory listing succeeded')
"

echo "Checking Kafka broker is reachable..."
python3 -c "
import os
from kafka import KafkaAdminClient
admin = KafkaAdminClient(bootstrap_servers=os.environ['KAFKA_BOOTSTRAP_SERVERS'])
admin.close()
print('Kafka broker connection succeeded')
"

echo "PASS: SFTP and Kafka infrastructure are both reachable"
