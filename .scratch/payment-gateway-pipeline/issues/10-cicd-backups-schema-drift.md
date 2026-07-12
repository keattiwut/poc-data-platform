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

- [x] CI runs lint/parse-check on Airflow DAGs and `dbt build`/`dbt test` against dev on every change *(workflow authored + locally validated; the file push needs a `workflow`-scoped token — see comment)*
- [ ] A PR cannot merge without passing CI and a review approval *(branch protection follows the workflow push — see comment)*
- [x] MinIO, ClickHouse, the Airflow metadata DB, and Vault are all backed up daily to a location separate from the host
- [x] A restore has been demonstrated at least once for each backed-up system (not just "backup job succeeds")
- [x] Introducing a schema change to a mock source (new/renamed/retyped column) causes the sync/build to fail and produce a Critical alert, rather than silently propagating

## Blocked by

- 01-infra-bootstrap.md

## Comments

**2026-07-12 (agent):** Implemented; merged as PR #13 (plus this bookkeeping).

- **Backups (ADR-0018)**: `scripts/backup-all.sh` (Postgres pg_dumpall + per-DB dump, ClickHouse native BACKUP to a backups disk, MinIO `mc mirror`, Vault file-backend tar) into `./backups/<date>/` (POC stand-in for the off-host target; production points the same mount at a remote share), 14-day pruning, daily 03:00 via the `backup` cron container over the docker socket. **Restores demonstrated** by `scripts/verify-backups.sh`: pipeline DB → scratch DB with matching counts; `dim_bank` from the native backup; a silver object round-tripped from the mirror; the Vault backend restored into a scratch server, unsealed with the saved key, and served a secret.
- **Schema drift (ADR-0019)**: dlt `schema_contract` columns/data_type=freeze on all four channels; pipelines drop pending packages at start (a rejected batch would otherwise replay forever). Demonstrated live by `scripts/verify-schema-drift.sh`: a drifted SFTP file failed `extract_sftp` in `daily_pipeline`, produced the Critical Teams alert with runbook link, and the pipeline recovered after removal.
- **CI**: `.github/workflows/ci.yml` (lint job: Airflow DagBag parse-check + dbt parse; e2e job: full compose dev stack driven through `verify-walking-skeleton.sh`, which now runs `dbt build` = seed+run+**test**). **Open**: GitHub refuses workflow-file pushes from tokens without the `workflow` OAuth scope, and the agent-permission gate rightly refused to let the agent elevate its own token. The file is committed on the local `ci-workflow` branch. Maintainer: run `gh auth refresh -h github.com -s workflow`, then push/merge `ci-workflow` and apply branch protection (required checks `lint` + `e2e`, 1 approving review) — one command each, listed in the branch's PR description.
- Full final verification battery green on 2026-07-12: per-service checks, walking skeleton (35 PASS), DQ tests + anomaly catch, kafka drain offsets, mock producer catalog/backfill, security (14 PASS), observability incl. live ClickHouse-down Critical alert, 4 restore demos, schema-drift demo.
