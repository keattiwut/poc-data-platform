#!/usr/bin/env bash
set -euo pipefail

# Generates the internal CA and per-service TLS certificates (Issue 09 /
# ADR-0017) into ./tls/ (git-ignored). Idempotent: skips anything that
# already exists, so bring-up scripts can call it unconditionally.
#
# POC ceiling: a self-signed local CA with 2-year leaf certs and no
# rotation; production replaces this with an organizational CA and issues
# per-service identities from it (the mounts and client CA config stay the
# same shape).

TLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tls"
mkdir -p "$TLS_DIR"
cd "$TLS_DIR"

if [ ! -f ca.crt ]; then
  # MSYS_NO_PATHCONV: Git Bash otherwise rewrites '/CN=...' into a Windows path.
  MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 1825 \
    -keyout ca.key -out ca.crt \
    -subj "/CN=payment-gateway-poc-ca" > /dev/null 2>&1
  echo "Generated CA: tls/ca.crt"
else
  echo "CA exists: tls/ca.crt"
fi

make_cert() {
  local name="$1" sans="$2"
  if [ -f "${name}.crt" ]; then
    echo "cert exists: tls/${name}.crt"
    return 0
  fi
  MSYS_NO_PATHCONV=1 openssl req -newkey rsa:2048 -nodes \
    -keyout "${name}.key" -out "${name}.csr" \
    -subj "/CN=${name}" > /dev/null 2>&1
  # Plain temp file, not <(process substitution): Windows openssl cannot
  # open /proc/NN/fd paths.
  printf "subjectAltName=%s" "$sans" > "${name}.ext"
  openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key \
    -CAcreateserial -days 730 -out "${name}.crt" \
    -extfile "${name}.ext" > /dev/null 2>&1
  rm -f "${name}.csr" "${name}.ext"
  echo "Generated cert: tls/${name}.crt (${sans})"
}

# In-network service names + host-side loopback for the verify scripts.
make_cert vault      "DNS:vault,DNS:localhost,IP:127.0.0.1"
make_cert minio      "DNS:minio,DNS:localhost,IP:127.0.0.1"
make_cert clickhouse "DNS:clickhouse,DNS:localhost,IP:127.0.0.1"
make_cert postgres   "DNS:postgres,DNS:localhost,IP:127.0.0.1"
make_cert superset-proxy "DNS:superset,DNS:localhost,IP:127.0.0.1"

echo "TLS material ready in tls/"
