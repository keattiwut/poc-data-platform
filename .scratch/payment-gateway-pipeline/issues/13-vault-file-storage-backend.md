Status: ready-for-agent

# Vault file storage backend instead of dev mode

## Parent

`review_recommendation.md` (finding 3) · `docs/adr/0023-vault-file-storage-backend.md`

## What to build

Vault runs in dev mode: in-memory storage, so any container restart wipes all secrets and the only safe recovery is `docker compose down -v` — destroying every data volume in the stack. Remove that failure mode by running Vault in server mode with the `file` storage backend on a Docker volume (ADR-0023).

Add a Vault HCL config (file backend, listener without TLS for now — TLS is Issue 09's scope), mount it and a `vault-data` volume in `docker-compose.yml`, and replace the dev-mode env vars. Add an init/unseal helper script: on first boot run `vault operator init` (single key share is fine for POC), capture the unseal key + root token to a git-ignored local file, and unseal; on subsequent boots just unseal. Update `vault/seed-secrets.sh`, `scripts/render-env-from-vault.sh`, and `scripts/verify-full-stack.sh` to use the new token source and unseal step. Rewrite the README's "dev-mode restart hazard" section to describe the new model (restart → unseal, no data loss).

## Acceptance criteria

- [ ] Vault runs in server mode with `file` storage on a named volume; no `VAULT_DEV_*` vars remain
- [ ] Init/unseal script: first boot initializes and stores key+token in a git-ignored file; later boots only unseal
- [ ] Secrets survive a `docker compose restart vault` (verify: seed, restart, unseal, read back)
- [ ] `verify-vault.sh` and `verify-full-stack.sh` updated and passing
- [ ] README hazard section replaced; `check-no-committed-secrets.sh` still passes (no key/token committed)

## Blocked by

- 01-infra-bootstrap.md
