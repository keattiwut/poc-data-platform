# Vault server-mode configuration (ADR-0023): `file` storage backend on the
# `vault-data` Docker volume so secrets survive container restarts.
# TLS enabled per ADR-0017 (Issue 09): cert from the local internal CA
# (scripts/generate-tls-certs.sh); clients verify against tls/ca.crt.

# /vault/file (not /vault/data): it's the image's canonical file-backend
# path — the entrypoint chowns it to the vault user; /vault/data stays
# root-owned and init fails with "permission denied".
storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/vault.crt"
  tls_key_file  = "/vault/tls/vault.key"
}

api_addr = "https://127.0.0.1:8200"
ui       = true
