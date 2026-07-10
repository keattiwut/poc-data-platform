# poc-data-pipeline — Infra Bootstrap

Operator notes for bringing up the local self-hosted data pipeline stack (Vault, Postgres, MinIO, Airflow, ClickHouse, Superset, Airbyte, dbt).

## Bring-up order

Vault must start and be seeded **before** any other service, because every other service's credentials are sourced from it at render time:

```bash
docker compose up -d vault
./vault/init-unseal.sh
./vault/seed-secrets.sh
./scripts/render-env-from-vault.sh
docker compose up -d
```

Or, simpler: just run `./scripts/verify-full-stack.sh`, which now does exactly this (start Vault, wait for it to respond, init/unseal it, seed it, render `.env`, then bring up the rest of the stack) before running per-service verification.

## Vault restarts and unsealing

Vault runs in **server mode** with the `file` storage backend on the `vault-data` volume ([ADR-0023](docs/adr/0023-vault-file-storage-backend.md)), so **secrets survive container restarts** — the old dev-mode "restart wipes everything, recover with `docker compose down -v`" hazard is gone.

The trade-off: after any restart, Vault comes back **sealed**. Recovery is just:

```bash
./vault/init-unseal.sh
```

On first boot this initializes Vault and writes the unseal key + root token to `vault/.vault-keys.json` (git-ignored — never commit it; if you lose it, Vault's storage is unrecoverable). On every later boot it only unseals. All scripts that talk to Vault read the root token from that file.

## Credential sourcing model

Credentials are sourced from Vault at a **render step**, not read live from Vault at container runtime:

1. `vault/seed-secrets.sh` writes secrets into Vault.
2. `scripts/render-env-from-vault.sh` reads them out of Vault and writes a plaintext `.env` file.
3. Docker Compose reads `.env` and injects the values as container environment variables.

This satisfies "credentials are never hardcoded and always originate from Vault," but it's a lighter-weight integration than a live runtime Vault read — the `.env` file is a point-in-time snapshot, and containers never talk to Vault themselves after that. A future issue could wire direct runtime Vault reads (e.g. via Vault Agent or the Vault Airflow/Kubernetes secrets backend) if that stronger guarantee becomes necessary.

## Airbyte's credentials are out of scope for this Vault

Airbyte is deployed via `abctl` into its own local `kind` Kubernetes cluster (see [ADR-0020](docs/adr/0020-airbyte-via-abctl.md)), separate from the Docker Compose stack the rest of these services run on. Airbyte manages its own credentials inside that cluster, independent of this Vault instance. This is a known, accepted gap in Vault coverage for this POC, not a bug — closing it would mean integrating Vault with Airbyte's own Kubernetes-based secrets handling, which is out of scope here.
