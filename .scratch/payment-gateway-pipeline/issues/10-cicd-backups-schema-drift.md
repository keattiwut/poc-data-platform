Status: ready-for-agent

# CI/CD pipeline + daily backups + fail-loud schema drift

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Implement the remaining maintenance decisions from ADR-0018 and ADR-0019, plus the CI/CD gate described in the PRD. This issue is only blocked by infra bootstrap and can run in parallel with the payment-domain issues.

Set up a CI pipeline that runs on every change to DAGs, dbt models, or Airbyte connector configs: lint/parse-check Airflow DAGs, and run `dbt build`/`dbt test` against the dev environment. Require passing CI and a reviewed PR before any change can reach prod.

Configure daily automated backups — separate from the host itself — for MinIO, ClickHouse (via its native backup tooling), the Airflow metadata Postgres DB, and Vault's storage backend, targeting a ~24h RPO.

Configure every Airbyte connector and the corresponding dbt source definitions to fail loudly (not auto-propagate) on schema drift — a new, renamed, or retyped column in a source should fail the sync/build and route to the Critical alert channel (ADR-0008) for manual review, rather than silently flowing through.

## Acceptance criteria

- [ ] CI runs lint/parse-check on Airflow DAGs and `dbt build`/`dbt test` against dev on every change
- [ ] A PR cannot merge without passing CI and a review approval
- [ ] MinIO, ClickHouse, the Airflow metadata DB, and Vault are all backed up daily to a location separate from the host
- [ ] A restore has been demonstrated at least once for each backed-up system (not just "backup job succeeds")
- [ ] Introducing a schema change to a mock source (new/renamed/retyped column) causes the sync/build to fail and produce a Critical alert, rather than silently propagating

## Blocked by

- 01-infra-bootstrap.md
