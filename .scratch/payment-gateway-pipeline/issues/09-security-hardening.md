Status: ready-for-agent

# Security hardening: PAN-masking validation, encryption, Superset exposure

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Implement the security decisions from ADR-0015, ADR-0016, and ADR-0017. This issue is only blocked by infra bootstrap and can run in parallel with the payment-domain issues.

Add a validation check (at the Airbyte connector config or dbt source-freshness/test layer) that rejects or flags any incoming field that looks like a raw PAN or full bank account number, enforcing the "never store raw PAN" requirement (ADR-0015) as a real, testable guard rather than just a documented policy — this must be validated before any future real Bank/Partner source is connected.

Enable server-side encryption on MinIO, encrypt ClickHouse's data volumes at the disk/OS level, and configure TLS between every internal service (Airflow, Airbyte, dbt, ClickHouse, Vault) — not just on the public-facing endpoint (ADR-0017).

Expose only Superset outside the internal network, with TLS termination, no default/example credentials, and rate limiting on the login endpoint; keep Airflow, Grafana, and the MinIO console reachable only from the internal network/VPN (ADR-0016).

Replace the shared MinIO root credential with per-service MinIO users (`review_recommendation.md` finding 7): read-only bronze/silver for ClickHouse's `minio_s3` named collection and dbt, write-silver for the promotion job, write-bronze for extraction. Vault stores each per-service credential; nothing except MinIO administration uses the root user.

## Acceptance criteria

- [ ] A validation guard rejects/flags fields resembling a raw PAN or full bank account number before they reach the lake
- [ ] MinIO server-side encryption is enabled; ClickHouse data volumes are encrypted at rest
- [ ] TLS is configured between every internal service, verified by inspecting actual traffic/config, not just assumed
- [ ] Superset is reachable from outside the internal network with TLS, no default credentials, and login rate limiting in place
- [ ] Airflow, Grafana, and the MinIO console are confirmed unreachable from outside the internal network
- [ ] Each MinIO consumer (ClickHouse, dbt, promotion job, extraction) authenticates with its own least-privilege user; root credentials are used only for MinIO administration

## Blocked by

- 01-infra-bootstrap.md
