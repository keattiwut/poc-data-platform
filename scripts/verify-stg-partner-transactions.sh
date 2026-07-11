#!/usr/bin/env bash
set -euo pipefail

# Git Bash ships a Schannel-built curl: a private CA has no revocation
# endpoint, so revocation checking must be turned off there for --cacert to
# verify (no-op on OpenSSL-built curls, which skip this branch).
if command curl --version | grep -q Schannel; then
  curl() { command curl --ssl-no-revoke "$@"; }
fi
set -a; source .env; set +a

echo "Checking stg_partner_transactions has rows in ClickHouse..."
# Credentials go through --netrc-file, not embedded in the URL - see
# scripts/verify-clickhouse.sh for why (visible in `ps aux` otherwise).
CH_NETRC=$(mktemp)
trap 'rm -f "$CH_NETRC"' EXIT
chmod 600 "$CH_NETRC"
printf 'machine localhost login %s password %s\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" > "$CH_NETRC"

COUNT=$(curl -sf --netrc-file "$CH_NETRC" --cacert tls/ca.crt "https://localhost:8124/?query=SELECT%20count(*)%20FROM%20stg_partner_transactions")
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: stg_partner_transactions has no rows (found: ${COUNT:-0})"
  exit 1
fi

echo "PASS: stg_partner_transactions has ${COUNT} rows"
