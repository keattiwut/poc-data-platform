# Operations & Maintenance Manual

Operator handbook for running, maintaining, and recovering the payment-gateway
data platform. Everything here was verified live against the running stack
(see [Verification scripts](#verification-scripts) for the proof commands).
Architecture background lives in [ARCHITECTURE.md](./ARCHITECTURE.md) and the
ADRs; incident procedures live in [runbooks/](./runbooks/).

---

## 1. System & network map

All services run on one Docker Compose project (`payment-gateway-pipeline`)
sharing the `payment-gateway-net` bridge network. In-network traffic uses
Compose service names; host access uses the published ports below.

**Exposure model (ADR-0016):** every published port binds `127.0.0.1`
(loopback = "internal network/VPN" stand-in) except the Superset TLS proxy,
which is the single externally reachable endpoint.

| Service | In-network address | Host port (loopback) | TLS | Purpose |
| --- | --- | --- | --- | --- |
| vault | `https://vault:8200` | 8200 | yes (internal CA) | Secrets (file backend, survives restarts, comes back **sealed**) |
| postgres | `postgres:5432` | 5432 | yes (`ssl=on`, clients `sslmode=require`) | Mock source DB (`pipeline`) + Airflow (`airflow`) + Superset (`superset`) metadata |
| minio | `https://minio:9000` | 9000 (API), 9001 (console) | yes (internal CA) | Data lake (`data-lake` bucket: `bronze/`, `silver/`), SSE-S3 encrypted |
| clickhouse | `https://clickhouse:8443` | 8124 → 8443 (https), 9002 (native) | yes; metrics :9363 stays http | Warehouse (MergeTree data on an AES-256 encrypted disk) |
| airflow-webserver | `http://airflow-webserver:8080` | 8080 | no (internal-only UI) | Airflow UI + execution API |
| airflow-scheduler | – | – | – | Runs ALL pipeline tasks (LocalExecutor); deps pip-installed at start |
| superset | `http://superset:8088` | 8088 (direct, internal) | via proxy | BI dashboards |
| **superset-proxy** | – | **8443 on all interfaces** | yes (TLS termination) | The ONLY external endpoint; login rate-limited (10 r/m → 429) |
| sftp | `sftp:22` | 12222 | SSH | Mock SFTP drop (`upload/`) |
| kafka | `kafka:9092` (internal), advertises `127.0.0.1:9094` externally | 9094 | no (mock source, PLAINTEXT — documented ceiling) | Mock message queue; data on the `kafka-data` volume |
| prometheus | `http://prometheus:9090` | 9090 | scrapes MinIO over TLS | Metrics + alert rules |
| alertmanager | `http://alertmanager:9093` | 9093 | – | Severity routing → Teams channels |
| grafana | `http://grafana:3000` | 3000 | – | Infra dashboards ("Pipeline Infra Health") + Loki logs |
| loki / promtail | `http://loki:3100` | 3100 | – | Log aggregation (Docker service discovery) |
| statsd-exporter | `statsd-exporter:9125/9102` | – | – | Airflow metrics bridge |
| mock-teams | `http://mock-teams:8080` | 18080 | – | Stand-in for the two Teams webhook channels (`/critical`, `/warning`) |
| backup | – | – | – | busybox crond, runs `scripts/backup-all.sh` daily at 03:00 |

Windows host note: the SFTP host port is 12222 (not 2222 — that fell into a
Windows excluded-port range) and Kafka's external listener advertises
`127.0.0.1`, not `localhost` (loopback binds are IPv4-only and
`localhost` resolves to `::1` first).

---

## 2. Bring-up, shutdown, cold-start recovery

### First bring-up / full bring-up

```bash
./scripts/verify-full-stack.sh
```

does the whole sequence: generate TLS material (idempotent) → start Vault →
init/unseal → seed secrets → render `.env` → `docker compose up -d` →
per-service verification. Manual equivalent:

```bash
./scripts/generate-tls-certs.sh      # idempotent; writes tls/ (git-ignored)
docker compose up -d vault
./vault/init-unseal.sh               # first boot: initializes + saves keys; later: unseals
./vault/seed-secrets.sh              # idempotent, skips existing secrets
./scripts/render-env-from-vault.sh   # writes .env (the credential snapshot)
docker compose up -d
```

The Airflow scheduler pip-installs its task dependencies at container start
(`_PIP_ADDITIONAL_REQUIREMENTS`, POC-only) — allow **3–5 minutes** before
tasks can run. Readiness check:

```bash
docker compose exec airflow-scheduler python -c "import dlt, confluent_kafka, paramiko, kafka"
```

### After any host reboot / Docker restart

Vault always comes back **sealed**. Recovery is exactly:

```bash
docker compose up -d
./vault/init-unseal.sh
```

Everything else recovers on its own — all stateful services persist on named
volumes (`vault-data`, `postgres-data`, `minio-data`, `clickhouse-data`,
`sftp-data`, `kafka-data`, `grafana-data`, `prometheus-data`, `loki-data`).
This was verified live: the full 19-service stack survived an unplanned host
shutdown with no data loss.

### Shutdown

```bash
docker compose down            # keeps all volumes (safe)
docker compose down -v         # DESTROYS all data - only for a full reset
```

---

## 3. Secrets & credentials

**Model (ADR-0006):** credentials never live in the repo. Vault is the source
of truth; `scripts/render-env-from-vault.sh` snapshots them into a
git-ignored `.env` that Docker Compose injects as container env. Coverage is
complete — there is no credential outside this flow.

| Secret path | Contents |
| --- | --- |
| `secret/postgres` | DB superuser + host/port/db |
| `secret/minio` | Root (administration-only) credentials |
| `secret/minio-services` | Per-service users: `svc_extraction` (rw bronze), `svc_promotion` (ro bronze / rw silver), `svc_warehouse` (ro silver) |
| `secret/airflow` | Fernet key + admin user |
| `secret/clickhouse`, `secret/superset`, `secret/grafana` | Service admin credentials |
| `secret/sftp`, `secret/kafka` | Mock source endpoints/credentials (in-network values; host scripts override) |
| `secret/encryption` | MinIO KMS key (SSE-S3) + ClickHouse disk-encryption key |

**Critical file:** `vault/.vault-keys.json` (git-ignored) holds the unseal
key and root token. Losing it makes Vault's storage — and both encryption
keys — unrecoverable. It is *not* inside any backup by design; store a copy
in your password manager.

**Rotating a credential:** write the new value to Vault
(`curl -X POST .../v1/secret/data/<path>` — see `vault/seed-secrets.sh` for
the API shape; the seed script itself skips existing secrets), then:

```bash
./scripts/render-env-from-vault.sh && docker compose up -d
```

Postgres/ClickHouse/MinIO store their own copy of the password at first
init, so rotating those also requires changing it inside the service (e.g.
`ALTER USER`), or a volume reset.

---

## 4. TLS certificate management

A local internal CA (`tls/ca.crt`, git-ignored) signs per-service certs with
SANs for the service name, `localhost`, and `127.0.0.1`:

```bash
./scripts/generate-tls-certs.sh    # idempotent - only creates what's missing
```

| File | Mounted into | Validity |
| --- | --- | --- |
| `tls/ca.crt` | every TLS client (scheduler `AWS_CA_BUNDLE`, ClickHouse `caConfig`, mc `~/.mc/certs/CAs`, Prometheus, host curls) | 5 years |
| `tls/{vault,minio,clickhouse,postgres,superset-proxy}.{crt,key}` | the respective server | 2 years |

**Renewal** (or after deleting `tls/`): regenerate, then restart the TLS
servers — `docker compose up -d vault minio clickhouse postgres superset-proxy`.
Clients read the CA from mounts/env and need no rebuild. Verify with
`./scripts/verify-security.sh` (section 3).

Windows/Git Bash quirk: host `curl` is Schannel-built; the verify scripts
already wrap it with `--ssl-no-revoke` (a private CA has no revocation
endpoint). Production upgrade: replace the local CA with an organizational
CA — the mounts and client config keep the same shape.

---

## 5. Backups & restore (ADR-0018, ~24h RPO)

### What runs automatically

The `backup` container (busybox crond) runs `scripts/backup-all.sh` daily at
**03:00** (after the 00:00 mock-producer and 02:00 pipeline runs). Manual run:
`./scripts/backup-all.sh`. Output lands in `./backups/` — the POC stand-in
for the off-host target; **in production, point this bind mount at a remote
share/object store** (the mechanism is identical). Retention: 14 days.

| System | Method | Location |
| --- | --- | --- |
| Postgres (all DBs) | `pg_dumpall --clean` + per-DB `pg_dump -Fc pipeline` | `backups/<date>/postgres-all.sql`, `pipeline.dump` |
| ClickHouse | native `BACKUP DATABASE default TO Disk('backups_disk', ...)` | `backups/clickhouse/<date>/default.zip` |
| MinIO lake | `mc mirror --overwrite --remove local/data-lake` | `backups/minio/data-lake/` |
| Vault storage | tar of the file backend | `backups/<date>/vault-file.tgz` |

Not backed up: the warehouse contents are fully rebuildable from the lake by
`dbt build`; Superset chart definitions live in the Postgres `superset` DB
(covered by `pg_dumpall`); `vault/.vault-keys.json` is deliberately excluded
(see §3).

### Restore procedures (each demonstrated by `./scripts/verify-backups.sh`)

**Postgres — single database:**
```bash
docker exec postgres createdb -U "$POSTGRES_USER" pipeline_restored
docker exec -i postgres pg_restore -U "$POSTGRES_USER" -d pipeline_restored --no-owner \
  < backups/<date>/pipeline.dump
# validate, then rename/swap or restore over the live DB the same way
```
Full-cluster disaster: `docker exec -i postgres psql -U "$POSTGRES_USER" -d postgres < backups/<date>/postgres-all.sql`.

**ClickHouse — table or database:**
```bash
docker compose exec clickhouse clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
  --query "RESTORE TABLE default.<table> AS default.<table>_restored FROM Disk('backups_disk', '<date>/default.zip')"
# or: RESTORE DATABASE default FROM ... (drop the live one first)
```
Usually unnecessary: re-running `daily_pipeline` rebuilds the warehouse from the lake.

**MinIO — object(s) back from the mirror:**
```bash
docker exec minio mc alias set local https://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
MSYS_NO_PATHCONV=1 docker exec minio mc cp /backups/data-lake/<path> local/data-lake/<path>
# whole lake: mc mirror /backups/data-lake local/data-lake
```

**Vault — storage backend:**
```bash
tar xzf backups/<date>/vault-file.tgz -C <restore-dir>
# run a vault server against <restore-dir>/vault/file (see verify-backups.sh §4
# for the exact scratch-container recipe), unseal with the key from
# vault/.vault-keys.json, verify, then swap the vault-data volume contents.
```

**After any restore:** `./scripts/verify-walking-skeleton.sh` proves the
whole platform end to end.

---

## 6. Routine operations

### Schedules (all Airflow, UI at http://localhost:8080)

| DAG | Schedule | What it does |
| --- | --- | --- |
| `mock_data_producer` | 00:00 daily | One simulated day of transactions across all 4 channels (first run: 45-day backfill). Pause it when real sources connect. |
| `daily_pipeline` | 02:00 daily | 4 dlt extractions → 2 promotions → `dbt build` (models + 38 tests) → source freshness. SLA: complete before 06:00. |
| `reset_mock_data` | manual only | Wipes mock Postgres, SFTP, Kafka topics, **dlt offset state**, lake, warehouse; reseeds a backfill; re-runs the pipeline. Demo resets only. |
| backup (cron container) | 03:00 daily | §5 |

### Dashboards & UIs (all loopback-only except the proxy)

- Business BI: `https://<host>:8443` (external, TLS) or `http://localhost:8088` — dashboard "Payment Gateway Performance" (12 charts)
- Infra health: `http://localhost:3000` (Grafana → Pipeline / Pipeline Infra Health)
- Airflow: `http://localhost:8080` · Prometheus: `:9090` · Alertmanager: `:9093` · MinIO console: `:9001`

Superset re-configuration (idempotent, run after chart/dataset changes):
`python scripts/configure-superset-dashboard.py`.

### Mock data knobs (env on the scheduler / at invocation)

`MOCK_DAILY_TRANSACTION_COUNT` (1500), `MOCK_BACKFILL_DAYS` (45),
`MOCK_ORPHAN_RATE` (0.10), `MOCK_DUPLICATE_RATE` (0.02),
`MOCK_MISSING_FILE_RATE` (0.05).

---

## 7. Monitoring, alerting, incident response

- **Metrics** (Prometheus): ClickHouse native `:9363`, MinIO
  `/minio/v2/metrics/cluster`, Airflow via statsd-exporter.
- **Logs** (Loki/Promtail): every container, labeled by service; correlated
  panel on the Grafana infra dashboard.
- **Alert channels** (CONTEXT.md severities): **Critical** = extraction/dbt
  failure, service unreachable, error-severity test; **Warning** = the rest.
  Two paths feed the same channels: Alertmanager rules
  (`prometheus/rules.yml`) and Airflow task-failure callbacks
  (`airflow/dags/alerting.py`). Both currently target the `mock-teams`
  receiver (`http://localhost:18080/messages` to inspect); **production:
  replace the two webhook URLs** in `alertmanager/alertmanager.yml` and the
  `TEAMS_*_WEBHOOK_URL` env vars with real Teams incoming webhooks (they then
  become secrets → move into the Vault render).
- **Runbooks** (linked from every alert): [clickhouse-unreachable](./runbooks/clickhouse-unreachable.md),
  [dbt-build-failed](./runbooks/dbt-build-failed.md),
  [extraction-task-failed](./runbooks/extraction-task-failed.md).
- **Freshness SLA**: silver source freshness warns at 4h stale (≈04:00 after
  a missed run) and errors at 8h (08:00) — bracketing the 6–8 AM window.

**Schema drift** (ADR-0019): a new/renamed/retyped column in any source fails
the extraction task (dlt schema contract, columns/data_type frozen) and
routes to Critical. To *accept* reviewed drift: update the mock schema/dbt
models as a code change, wipe the affected channel's frozen schema
(`docker compose exec airflow-scheduler rm -rf /home/airflow/.dlt/pipelines/bronze_<channel>`
plus the destination copy under `bronze/<dataset>/`), and re-run.

---

## 8. Maintenance tasks

| Task | Cadence | How |
| --- | --- | --- |
| Verify backups restore | monthly | `./scripts/verify-backups.sh` |
| TLS cert renewal | before 2-year leaf expiry | §4 |
| Image upgrades | as needed | bump the pinned tag in `docker-compose.yml`, `docker compose up -d <svc>`, run the service's verify script; for ClickHouse re-run `scripts/verify-clickhouse-s3-join-bug.sh` (ADR-0022) |
| Python dep upgrades | as needed | `_PIP_ADDITIONAL_REQUIREMENTS` on the scheduler (POC route; the non-POC fix is a custom image) |
| Disk usage | watch `MinIOLowFreeSpace` warning | prune old bronze loads if needed (silver/warehouse rebuild from bronze) |
| Backup pruning | automatic (14 days) | `scripts/backup-all.sh` |
| dim_date horizon | before 2028 | extend the range in `dbt/payment_gateway/models/dimensions/dim_date.sql` |

**Kafka/dlt state invariant:** anything that deletes Kafka topics MUST also
wipe dlt's consumed-offset state (local `~/.dlt/pipelines/bronze_kafka` in
the scheduler + the destination copy under `bronze/kafka_drain/`), or the
next drain silently skips everything. `reset_mock_data` does this correctly;
don't hand-delete topics without it.

---

## 9. Verification scripts

Every operational claim in this document is executable. The full battery
(all green as of 2026-07-12):

| Script | Proves |
| --- | --- |
| `verify-full-stack.sh` | Bring-up sequence + per-service health |
| `verify-walking-skeleton.sh` | End-to-end: generator → 4-channel dlt extraction → lake → dbt build (models + tests) → ClickHouse → 12-chart dashboard, totals matching |
| `verify-dq-tests.sh` | Data-quality tests pass clean AND catch injected duplicates |
| `verify-kafka-drain.sh` | Kafka batch drain + offset tracking |
| `verify-mock-producer.sh` | Backfill depth, catalog coverage, distinct profiles |
| `verify-security.sh` | PAN guard, encryption at rest, TLS everywhere, exposure model, least-privilege lake access |
| `verify-observability.sh` | Metrics/logs/dashboards + a LIVE outage → Critical Teams alert |
| `verify-backups.sh` | A real restore of all four backed-up systems |
| `verify-schema-drift.sh` | Drift fails loudly → Critical alert → recovery |

---

## 10. Known platform quirks (Windows/Docker Desktop host)

- **Vault comes back sealed** after every restart → `./vault/init-unseal.sh`.
- **Excluded port ranges** shift after reboots (`netsh interface ipv4 show
  excludedportrange protocol=tcp`); that's why SFTP publishes 12222.
- **Git Bash path mangling**: prefix `MSYS_NO_PATHCONV=1` on `docker exec`
  commands that pass in-container absolute paths — but never export it
  globally (it breaks `/dev/null` translation for native tools).
- **Schannel curl** needs `--ssl-no-revoke` with the private CA (the scripts
  shim this automatically).
- **Loopback binds are IPv4-only**: use `127.0.0.1`, not `localhost`, for
  host-side Kafka clients.
- **Scheduler cold start is slow** (pip install at boot, POC-only).
