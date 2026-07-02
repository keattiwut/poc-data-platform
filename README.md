# poc-data-pipeline — Infra Bootstrap

Operator notes for bringing up the local self-hosted data pipeline stack (Vault, Postgres, MinIO, Airflow, ClickHouse, Superset, Airbyte, dbt).

## Bring-up order

Vault must start and be seeded **before** any other service, because every other service's credentials are sourced from it at render time:

```bash
docker compose up -d vault
./vault/seed-secrets.sh
./scripts/render-env-from-vault.sh
docker compose up -d
```

Or, simpler: just run `./scripts/verify-full-stack.sh`, which now does exactly this (start Vault, wait for its healthcheck, seed it, render `.env`, then bring up the rest of the stack) before running per-service verification.

## Vault dev-mode restart hazard

Vault runs in **dev mode** for this POC (`VAULT_DEV_ROOT_TOKEN_ID` in `docker-compose.yml`), which means **in-memory storage only** — all secrets are lost if the Vault container restarts.

`vault/seed-secrets.sh` is idempotent (it skips any secret path that already exists), which is normally what you want. But if Vault's storage was wiped by a restart, the seeder can't tell the difference between "never seeded" and "storage just got wiped" — it will happily generate **new random passwords** for everything. Those new passwords will not match what's already baked into the Postgres/MinIO/ClickHouse data volumes from their *original* initialization, and every service will start rejecting the new credentials.

**If Vault ever restarts unexpectedly, do not just re-seed.** The fix is:

```bash
docker compose down -v   # wipes all data volumes, including the stale credentials
./scripts/verify-full-stack.sh   # fresh bring-up: new Vault secrets + freshly-initialized volumes that match them
```

## Credential sourcing model

Credentials are sourced from Vault at a **render step**, not read live from Vault at container runtime:

1. `vault/seed-secrets.sh` writes secrets into Vault.
2. `scripts/render-env-from-vault.sh` reads them out of Vault and writes a plaintext `.env` file.
3. Docker Compose reads `.env` and injects the values as container environment variables.

This satisfies "credentials are never hardcoded and always originate from Vault," but it's a lighter-weight integration than a live runtime Vault read — the `.env` file is a point-in-time snapshot, and containers never talk to Vault themselves after that. A future issue could wire direct runtime Vault reads (e.g. via Vault Agent or the Vault Airflow/Kubernetes secrets backend) if that stronger guarantee becomes necessary.

## Airbyte's credentials are out of scope for this Vault

Airbyte is deployed via `abctl` into its own local `kind` Kubernetes cluster (see [ADR-0020](docs/adr/0020-airbyte-via-abctl.md)), separate from the Docker Compose stack the rest of these services run on. Airbyte manages its own credentials inside that cluster, independent of this Vault instance. This is a known, accepted gap in Vault coverage for this POC, not a bug — closing it would mean integrating Vault with Airbyte's own Kubernetes-based secrets handling, which is out of scope here.
