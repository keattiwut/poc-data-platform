#!/usr/bin/env bash
set -euo pipefail

# Git Bash ships a Schannel-built curl: a private CA has no revocation
# endpoint, so revocation checking must be turned off there for --cacert to
# verify (no-op on OpenSSL-built curls, which skip this branch).
if command curl --version | grep -q Schannel; then
  curl() { command curl --ssl-no-revoke "$@"; }
fi

# .env has plain KEY=VALUE lines (no `export`), so a caller's `source .env`
# only sets shell variables in the caller's shell — they are not inherited by
# this script, which runs as a separate process. Re-source with `set -a` here
# so CLICKHOUSE_PASSWORD is actually exported into this process's environment.
# Same pattern used in scripts/verify-postgres-minio.sh.
set -a
source .env
set +a

echo "Checking ClickHouse HTTP interface..."
# Credentials go through --netrc-file, not embedded in the URL: a URL-embedded
# user:pass@host is visible to any local user via `ps aux` while curl runs.
# netrc keeps it in a 600-permission temp file curl reads directly instead.
CH_NETRC=$(mktemp)
trap 'rm -f "$CH_NETRC"' EXIT
chmod 600 "$CH_NETRC"
printf 'machine localhost login %s password %s\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" > "$CH_NETRC"

# Host-side port is 8124, not ClickHouse's default 8123: on this dev machine,
# 8123 is taken by a pre-existing socksproxy.exe Windows service. See
# docker-compose.yml's clickhouse service ports mapping.
RESULT=$(curl -sf --netrc-file "$CH_NETRC" --cacert tls/ca.crt "https://localhost:8124/?query=SELECT%201")
if [ "$RESULT" != "1" ]; then
  echo "FAIL: expected '1', got '${RESULT}'"
  exit 1
fi

echo "PASS: ClickHouse is up and query-able"
