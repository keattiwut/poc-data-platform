Status: ready-for-agent

# Infra bootstrap: Docker Compose stack + Vault-backed secrets

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Stand up the self-hosted, on-prem core infrastructure (ADR-0002, ADR-0004) via Docker Compose: Apache Airflow, MinIO, Airbyte, a dbt project skeleton (empty models, correctly configured to target ClickHouse), ClickHouse, Apache Superset, and HashiCorp Vault, all running and able to reach each other on the Compose network.

No business logic (DAGs, dbt models, dashboards) is built in this issue — it's a prefactor step. The one exception is credential wiring: every service's database/API credentials must be sourced from Vault (ADR-0006) rather than hardcoded, `.env` files, or Airflow's native Connections store. Seed Vault with placeholder/dev credentials for each service as part of this issue.

Verify the stack by confirming each service's health endpoint/UI is reachable, and that at least one service (e.g. Airflow) successfully retrieves a credential from Vault at startup rather than from a local config file.

## Acceptance criteria

- [ ] Airflow, MinIO, Airbyte, ClickHouse, Superset, and Vault all start via `docker compose up` and report healthy
- [ ] A dbt project exists, configured with a ClickHouse target, and `dbt debug` succeeds
- [ ] Vault is initialized/unsealed and holds credentials for every other service in the stack
- [ ] At least one service demonstrably reads its credential from Vault at runtime, not from a hardcoded value
- [ ] No plaintext credentials committed to the repo or baked into Compose files

## Blocked by

None - can start immediately
