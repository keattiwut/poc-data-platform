# Vault server-mode configuration (ADR-0023): `file` storage backend on the
# `vault-data` Docker volume so secrets survive container restarts.
# TLS is deliberately left disabled here — enabling it is a separate issue
# (security hardening), not this one's scope.

# /vault/file (not /vault/data): it's the image's canonical file-backend
# path — the entrypoint chowns it to the vault user; /vault/data stays
# root-owned and init fails with "permission denied".
storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:8200"
ui       = true
