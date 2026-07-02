# Walking Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the entire pipeline path end-to-end with the thinnest possible slice — one source (mock Partner-side transactions in Postgres), no Bank-side reconciliation yet — flowing through Airbyte, the MinIO lake, dbt, ClickHouse, and into one Superset chart.

**Architecture:** A minimal Python script seeds Partner-side Transaction records directly into the `pipeline` Postgres database (already provisioned by Issue 01). An Airbyte connection (Postgres source → S3/MinIO destination, configured via Airbyte's API) syncs those rows into the lake's bronze zone as Parquet. A small DuckDB script promotes bronze to silver (dedup by Transaction ID, keep latest). dbt models read silver directly from MinIO using ClickHouse's native `s3()` table function, and materialize `fct_transactions` (Bank-side columns present but NULL) as a ClickHouse `ReplacingMergeTree` table with a `fct_transactions_current` dedup view on top. Superset gets a ClickHouse data source and one chart (transaction volume by day) reading from that view.

**Tech Stack:** Python (stdlib only — no Faker yet, that's Issue 05), Airbyte (Postgres source, S3 destination, via its REST API), DuckDB (bronze→silver promotion), dbt-clickhouse (staging + marts models using ClickHouse's `s3()` table function), ClickHouse `ReplacingMergeTree`, Apache Superset (ClickHouse SQLAlchemy driver + API/CLI-scripted dashboard).

## Global Constraints

- **Transaction domain model** (CONTEXT.md): a Transaction has a fixed lifecycle — initiated → authorized → captured → settled, plus failed/refunded terminal branches — and a gateway-assigned Transaction ID (ADR-0009), a UUID generated at initiation.
- `fct_transactions` is an **accumulating snapshot** (ADR-0005): one row per Transaction ID, milestone timestamp columns, updated via upsert — never Type 2 SCD history.
- `fct_transactions` uses ClickHouse's **`ReplacingMergeTree`** engine; all consumers query **`fct_transactions_current`**, a dedup view built with `argMax()` — never the raw table directly, never `FINAL` in ad hoc queries (ADR-0014).
- **No gold Parquet zone** — dbt reads silver-zone Parquet directly and materializes into ClickHouse (ADR-0013).
- In this slice, Bank-side columns on `fct_transactions` are present but `NULL` — this is intentional groundwork for the full-outer-join reconciliation Issue 03 adds (ADR-0012), not a bug.
- **Every credential is sourced from Vault** (ADR-0006) via the established seed → render → `.env` pattern from Issue 01 — never hardcoded, never committed. Extend `vault/seed-secrets.sh` and `scripts/render-env-from-vault.sh` exactly as Issue 01's tasks did, for any new credential this plan introduces (Airbyte API auth if needed, MinIO access key/secret already exist from Issue 01 — reuse `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`).
- No DAGs are required to exist yet for this slice — "run this manually" is explicitly acceptable per Issue 02's brief. Do not build the daily-scheduled generator DAG or fan-out DAG shape; that's Issues 05 and beyond.
- `core.fileMode` is `false` in this worktree (inherited from Issue 01) — every new script that needs `chmod +x` must additionally get `git update-index --chmod=+x <path>` before committing, or the executable bit will not actually be staged. Verify with `git ls-files -s <path>` shows `100755`.

---

## File Structure

- `mock/schema.sql` — Postgres DDL for the `partner_transactions` table
- `mock/generate_partner_transactions.py` — seeds Partner-side Transaction records into Postgres
- `scripts/promote-bronze-to-silver.py` — DuckDB script: reads bronze Parquet from MinIO, dedups by Transaction ID (keep latest by `updated_at`), writes silver Parquet
- `scripts/configure-airbyte-partner-source.sh` — configures the Airbyte Postgres source, S3/MinIO destination, and connection via Airbyte's API; triggers a sync
- `dbt/payment_gateway/models/staging/stg_partner_transactions.sql` — reads silver Parquet via ClickHouse's `s3()` table function
- `dbt/payment_gateway/models/staging/stg_partner_transactions.yml` — column docs/tests scaffold (no tests enforced yet — that's Issue 07)
- `dbt/payment_gateway/models/marts/fct_transactions.sql` — minimal fact (Partner-side populated, Bank-side NULL), `ReplacingMergeTree`
- `dbt/payment_gateway/models/marts/fct_transactions_current.sql` — dedup view via `argMax()`
- `scripts/configure-superset-clickhouse.sh` — adds the ClickHouse SQLAlchemy driver to Superset's image, configures the database connection, dataset, chart, and dashboard
- `scripts/verify-walking-skeleton.sh` — end-to-end verification: generator → Airbyte → lake → dbt → ClickHouse → Superset chart, all in one run

---

### Task 1: Mock Partner-side transaction generator

**Files:**
- Create: `mock/schema.sql`
- Create: `mock/generate_partner_transactions.py`
- Create: `scripts/verify-mock-generator.sh`

**Interfaces:**
- Produces: a `pipeline.partner_transactions` Postgres table, populated with rows having columns: `transaction_id` (UUID text, gateway-assigned), `partner_id` (text), `amount_cents` (bigint), `currency` (text, always `'USD'` for this slice per ADR single-currency decision), `state` (text: one of `initiated`, `authorized`, `captured`, `settled`, `failed`, `refunded`), `decline_reason` (text, nullable), `initiated_at`, `authorized_at`, `captured_at`, `settled_at`, `failed_at`, `refunded_at` (all `timestamptz`, nullable except `initiated_at`), `updated_at` (`timestamptz`, not null — bumped on every state change, used later for silver dedup and incremental extraction).
- Later tasks (Task 2 onward) read this table via Airbyte; the exact column names above are load-bearing — do not rename without updating every downstream task.

- [ ] **Step 1: Write the failing verification script**

Create `scripts/verify-mock-generator.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking partner_transactions table has rows..."
COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -tAc \
  "SELECT count(*) FROM partner_transactions;")
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: partner_transactions has no rows (found: ${COUNT:-0})"
  exit 1
fi

echo "Checking every row has a non-null transaction_id and state..."
NULLS=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d pipeline -tAc \
  "SELECT count(*) FROM partner_transactions WHERE transaction_id IS NULL OR state IS NULL;")
if [ "${NULLS:-1}" -ne 0 ]; then
  echo "FAIL: found rows with null transaction_id or state"
  exit 1
fi

echo "PASS: partner_transactions has ${COUNT} rows, all with valid transaction_id/state"
```

Make it executable: `chmod +x scripts/verify-mock-generator.sh`

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/verify-mock-generator.sh`
Expected: FAIL — `relation "partner_transactions" does not exist` (table doesn't exist yet).

- [ ] **Step 3: Write the table DDL**

Create `mock/schema.sql`:

```sql
CREATE TABLE IF NOT EXISTS partner_transactions (
    transaction_id   TEXT PRIMARY KEY,
    partner_id       TEXT NOT NULL,
    amount_cents     BIGINT NOT NULL,
    currency         TEXT NOT NULL DEFAULT 'USD',
    state            TEXT NOT NULL,
    decline_reason   TEXT,
    initiated_at     TIMESTAMPTZ NOT NULL,
    authorized_at    TIMESTAMPTZ,
    captured_at      TIMESTAMPTZ,
    settled_at       TIMESTAMPTZ,
    failed_at        TIMESTAMPTZ,
    refunded_at      TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL
);
```

- [ ] **Step 4: Write the generator script**

Create `mock/generate_partner_transactions.py`:

```python
#!/usr/bin/env python3
"""Seeds mock Partner-side Transaction records into the pipeline Postgres database.

Minimal generator for the walking-skeleton slice (Issue 02) - not the full
ADR-0010 spec (no Bank side, no anomalies, no daily scheduling, no Faker).
"""
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

import psycopg2

TRANSACTION_COUNT = int(os.environ.get("MOCK_TRANSACTION_COUNT", "200"))
PARTNER_IDS = ["partner_acme", "partner_globex", "partner_initech"]
DECLINE_REASONS = ["insufficient_funds", "fraud_suspected", "technical_error", "invalid_account"]

# Roughly: 90% initiated->authorized, of those 95% ->captured->settled,
# 5% fail after authorization. 10% never even authorize (declined outright).
AUTH_RATE = 0.90
SETTLE_RATE_GIVEN_AUTH = 0.95


def random_timestamp_today() -> datetime:
    now = datetime.now(timezone.utc)
    seconds_ago = random.randint(0, 23 * 3600)
    return now - timedelta(seconds=seconds_ago)


def build_transaction() -> dict:
    transaction_id = str(uuid.uuid4())
    partner_id = random.choice(PARTNER_IDS)
    amount_cents = random.randint(500, 250_000)
    initiated_at = random_timestamp_today()

    row = {
        "transaction_id": transaction_id,
        "partner_id": partner_id,
        "amount_cents": amount_cents,
        "currency": "USD",
        "state": "initiated",
        "decline_reason": None,
        "initiated_at": initiated_at,
        "authorized_at": None,
        "captured_at": None,
        "settled_at": None,
        "failed_at": None,
        "refunded_at": None,
    }

    if random.random() < AUTH_RATE:
        authorized_at = initiated_at + timedelta(seconds=random.randint(1, 30))
        row["authorized_at"] = authorized_at
        row["state"] = "authorized"

        if random.random() < SETTLE_RATE_GIVEN_AUTH:
            captured_at = authorized_at + timedelta(seconds=random.randint(1, 60))
            settled_at = captured_at + timedelta(minutes=random.randint(1, 120))
            row["captured_at"] = captured_at
            row["settled_at"] = settled_at
            row["state"] = "settled"
        else:
            failed_at = authorized_at + timedelta(seconds=random.randint(1, 60))
            row["failed_at"] = failed_at
            row["state"] = "failed"
            row["decline_reason"] = random.choice(DECLINE_REASONS)
    else:
        failed_at = initiated_at + timedelta(seconds=random.randint(1, 30))
        row["failed_at"] = failed_at
        row["state"] = "failed"
        row["decline_reason"] = random.choice(DECLINE_REASONS)

    row["updated_at"] = max(
        t for t in [
            row["initiated_at"], row["authorized_at"], row["captured_at"],
            row["settled_at"], row["failed_at"], row["refunded_at"],
        ] if t is not None
    )
    return row


def main() -> None:
    conn = psycopg2.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        dbname="pipeline",
    )
    try:
        with conn.cursor() as cur:
            with open("mock/schema.sql") as f:
                cur.execute(f.read())

            rows = [build_transaction() for _ in range(TRANSACTION_COUNT)]
            for row in rows:
                cur.execute(
                    """
                    INSERT INTO partner_transactions (
                        transaction_id, partner_id, amount_cents, currency, state,
                        decline_reason, initiated_at, authorized_at, captured_at,
                        settled_at, failed_at, refunded_at, updated_at
                    ) VALUES (
                        %(transaction_id)s, %(partner_id)s, %(amount_cents)s, %(currency)s, %(state)s,
                        %(decline_reason)s, %(initiated_at)s, %(authorized_at)s, %(captured_at)s,
                        %(settled_at)s, %(failed_at)s, %(refunded_at)s, %(updated_at)s
                    )
                    ON CONFLICT (transaction_id) DO NOTHING
                    """,
                    row,
                )
        conn.commit()
        print(f"Seeded {TRANSACTION_COUNT} partner_transactions rows.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
```

Note: `psycopg2` (or `psycopg2-binary`) must be available in whatever Python environment runs this — check first with `python3 -c "import psycopg2"`, `pip install psycopg2-binary` if missing (same as Task 7's dbt-clickhouse install pattern from Issue 01).

- [ ] **Step 5: Run the generator and verification**

Run:
```bash
set -a; source .env; set +a
python3 mock/generate_partner_transactions.py
./scripts/verify-mock-generator.sh
```

Expected: `PASS: partner_transactions has 200 rows, all with valid transaction_id/state`

- [ ] **Step 6: Commit**

```bash
git add mock/schema.sql mock/generate_partner_transactions.py scripts/verify-mock-generator.sh
git commit -m "feat: add minimal Partner-side mock transaction generator"
```

---

### Task 2: Airbyte Postgres source → MinIO bronze zone

**Files:**
- Create: `scripts/configure-airbyte-partner-source.sh`
- Create: `scripts/verify-airbyte-bronze-sync.sh`

**Interfaces:**
- Consumes: `partner_transactions` table from Task 1; MinIO credentials (`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`) already in `.env` from Issue 01; the `data-lake` bucket already created by Issue 01's `minio-init`.
- Produces: Parquet files under `data-lake/bronze/partner_transactions/` in MinIO, containing every row from `partner_transactions`. Task 3 reads from this exact path.

**Important — this task involves real API/version discovery.** Airbyte's exact REST API shape (endpoint paths, payload structure for creating a Postgres source, an S3 destination, and a connection) depends on the specific Airbyte version installed by Issue 01 (`abctl`-provisioned, confirmed in Issue 01's report as `App Version: 2.1.0`/`1.15.1` for its Helm charts). Do not guess at exact API payloads — discover the real schema by querying Airbyte's own OpenAPI spec (typically served at `http://localhost:8000/api/v1/documentation` or similar — check what's actually being served) or by using the Airbyte UI at `http://localhost:8000` to manually configure once and then reverse-engineer the equivalent API calls from the UI's network requests, if the API documentation route is unclear. The goal is a **scriptable, re-runnable** configuration (not a one-off manual UI click-through) — the script must be able to create the source/destination/connection from scratch and trigger a sync.

- [ ] **Step 1: Write the failing verification script**

Create `scripts/verify-airbyte-bronze-sync.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking bronze-zone Parquet files exist for partner_transactions..."
COUNT=$(docker compose exec -T minio mc find local/data-lake/bronze/partner_transactions --name "*.parquet" 2>/dev/null | wc -l)
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no Parquet files found under data-lake/bronze/partner_transactions/"
  exit 1
fi

echo "PASS: found ${COUNT} Parquet file(s) in bronze/partner_transactions"
```

Make it executable: `chmod +x scripts/verify-airbyte-bronze-sync.sh`

(Adjust the `mc find`/`mc alias` invocation if needed to match how prior tasks' verify scripts authenticate `mc` against MinIO — see `scripts/verify-postgres-minio.sh` from Issue 01 for the `mc alias set` pattern with real credentials.)

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/verify-airbyte-bronze-sync.sh`
Expected: FAIL — no Parquet files exist yet (no connector configured).

- [ ] **Step 3: Discover Airbyte's real API and write the configuration script**

Create `scripts/configure-airbyte-partner-source.sh`. It must, against the real running Airbyte instance:

1. Create (or find existing, idempotently — check-before-create, same principle as Vault's `put_secret` idempotency from Issue 01) a **Postgres source connector** pointing at: host `postgres` (the Docker Compose service name — but note Airbyte itself runs inside a separate `kind` Kubernetes cluster per ADR-0020, not the same Docker network as `docker-compose.yml`'s services, so verify what hostname/IP Airbyte's pods can actually use to reach the `postgres` container — this may require the host machine's IP or `host.docker.internal`/a k8s-reachable address rather than the Docker Compose service name; discover and document whatever actually works), database `pipeline`, table `partner_transactions`, credentials from `$POSTGRES_USER`/`$POSTGRES_PASSWORD` (already in `.env`).
2. Create (or find existing) an **S3-compatible destination connector** pointing at MinIO: endpoint `http://<reachable-minio-address>:9000` (same reachability caveat as above — Airbyte's pods need network access to MinIO), bucket `data-lake`, path prefix `bronze/partner_transactions`, format Parquet, credentials from `$MINIO_ROOT_USER`/`$MINIO_ROOT_PASSWORD`.
3. Create (or find existing) a **connection** linking the source table to the destination, sync mode "full refresh | overwrite" is acceptable for this slice (incremental sync tuning is out of scope here).
4. Trigger a manual sync via the API and wait for it to complete (poll job status).

Make it executable: `chmod +x scripts/configure-airbyte-partner-source.sh`

If Airbyte's pods genuinely cannot reach the host's Docker Compose network (a real possible blocker given the `kind`-cluster isolation from ADR-0020), report this as BLOCKED with a clear diagnosis rather than working around it with something that isn't a real Airbyte sync — this is exactly the kind of architectural discovery worth escalating rather than silently hacking around.

- [ ] **Step 4: Run the configuration and verification**

Run:
```bash
set -a; source .env; set +a
./scripts/configure-airbyte-partner-source.sh
./scripts/verify-airbyte-bronze-sync.sh
```

Expected: `PASS: found N Parquet file(s) in bronze/partner_transactions`

- [ ] **Step 5: Commit**

```bash
git add scripts/configure-airbyte-partner-source.sh scripts/verify-airbyte-bronze-sync.sh
git commit -m "feat: configure Airbyte Postgres source -> MinIO bronze sync"
```

---

### Task 3: Bronze → silver promotion

**Files:**
- Create: `scripts/promote-bronze-to-silver.py`
- Create: `scripts/verify-silver-promotion.sh`

**Interfaces:**
- Consumes: bronze Parquet at `data-lake/bronze/partner_transactions/` (Task 2).
- Produces: deduplicated Parquet at `data-lake/silver/partner_transactions/` — one row per `transaction_id`, keeping the row with the latest `updated_at` if Airbyte produced duplicates. Task 4's dbt staging model reads from this exact path.

- [ ] **Step 1: Write the failing verification script**

Create `scripts/verify-silver-promotion.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking silver-zone Parquet exists for partner_transactions..."
COUNT=$(docker compose exec -T minio mc find local/data-lake/silver/partner_transactions --name "*.parquet" 2>/dev/null | wc -l)
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no Parquet files found under data-lake/silver/partner_transactions/"
  exit 1
fi

echo "PASS: found ${COUNT} Parquet file(s) in silver/partner_transactions"
```

Make it executable: `chmod +x scripts/verify-silver-promotion.sh`

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/verify-silver-promotion.sh`
Expected: FAIL — no silver Parquet exists yet.

- [ ] **Step 3: Write the promotion script**

Create `scripts/promote-bronze-to-silver.py`:

```python
#!/usr/bin/env python3
"""Promotes bronze-zone partner_transactions Parquet to silver: dedups by
transaction_id, keeping the row with the latest updated_at."""
import os

import duckdb

MINIO_ENDPOINT = "localhost:9000"


def main() -> None:
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute(f"""
        SET s3_endpoint='{MINIO_ENDPOINT}';
        SET s3_access_key_id='{os.environ["MINIO_ROOT_USER"]}';
        SET s3_secret_access_key='{os.environ["MINIO_ROOT_PASSWORD"]}';
        SET s3_use_ssl=false;
        SET s3_url_style='path';
    """)

    con.execute("""
        COPY (
            SELECT * EXCLUDE (rn) FROM (
                SELECT *,
                       ROW_NUMBER() OVER (
                           PARTITION BY transaction_id
                           ORDER BY updated_at DESC
                       ) AS rn
                FROM read_parquet('s3://data-lake/bronze/partner_transactions/**/*.parquet')
            )
            WHERE rn = 1
        ) TO 's3://data-lake/silver/partner_transactions/data.parquet' (FORMAT PARQUET);
    """)
    print("Promoted bronze/partner_transactions -> silver/partner_transactions")


if __name__ == "__main__":
    main()
```

Note: `duckdb` must be available — check first with `python3 -c "import duckdb"`, `pip install duckdb` if missing.

- [ ] **Step 4: Run the promotion and verification**

Run:
```bash
set -a; source .env; set +a
python3 scripts/promote-bronze-to-silver.py
./scripts/verify-silver-promotion.sh
```

Expected: `PASS: found 1 Parquet file(s) in silver/partner_transactions`

- [ ] **Step 5: Commit**

```bash
git add scripts/promote-bronze-to-silver.py scripts/verify-silver-promotion.sh
git commit -m "feat: add bronze-to-silver promotion script (DuckDB dedup)"
```

---

### Task 4: dbt staging model reading silver via ClickHouse's s3() function

**Files:**
- Create: `dbt/payment_gateway/models/staging/stg_partner_transactions.sql`
- Create: `dbt/payment_gateway/models/staging/stg_partner_transactions.yml`
- Create: `scripts/verify-stg-partner-transactions.sh`

**Interfaces:**
- Consumes: silver Parquet at `data-lake/silver/partner_transactions/` (Task 3); `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD` from `.env` (Issue 01); `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` from `.env`.
- Produces: a ClickHouse view (or table) `stg_partner_transactions` with columns matching Task 1's schema (renamed to the domain-consistent staging convention: `transaction_id`, `partner_id`, `amount_cents`, `currency`, `state`, `decline_reason`, `initiated_at`, `authorized_at`, `captured_at`, `settled_at`, `failed_at`, `refunded_at`, `updated_at`). Task 5's `fct_transactions` model selects from this.

- [ ] **Step 1: Write the failing verification script**

Create `scripts/verify-stg-partner-transactions.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking stg_partner_transactions has rows in ClickHouse..."
COUNT=$(curl -sf "http://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@localhost:8124/?query=SELECT%20count(*)%20FROM%20stg_partner_transactions")
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "FAIL: stg_partner_transactions has no rows (found: ${COUNT:-0})"
  exit 1
fi

echo "PASS: stg_partner_transactions has ${COUNT} rows"
```

Make it executable: `chmod +x scripts/verify-stg-partner-transactions.sh`

- [ ] **Step 2: Run it to confirm it fails**

Run: `set -a; source .env; set +a; ./scripts/verify-stg-partner-transactions.sh`
Expected: FAIL — `stg_partner_transactions` doesn't exist in ClickHouse yet.

- [ ] **Step 3: Write the staging model**

Create `dbt/payment_gateway/models/staging/stg_partner_transactions.sql`:

```sql
{{ config(materialized='view') }}

SELECT
    transaction_id,
    partner_id,
    amount_cents,
    currency,
    state,
    decline_reason,
    initiated_at,
    authorized_at,
    captured_at,
    settled_at,
    failed_at,
    refunded_at,
    updated_at
FROM s3(
    'http://minio:9000/data-lake/silver/partner_transactions/*.parquet',
    '{{ env_var("MINIO_ROOT_USER") }}',
    '{{ env_var("MINIO_ROOT_PASSWORD") }}',
    'Parquet'
)
```

Note: this uses ClickHouse's native `s3()` table function, reachable from inside the `clickhouse` container via the Docker Compose network using the service name `minio` (not `localhost` — that only works from the host). If `dbt debug`/`dbt run` connects to ClickHouse from the host machine but ClickHouse itself executes this query server-side (inside its own container), `minio:9000` is the correct address for ClickHouse to reach MinIO over the Compose network — this should just work since both are Compose services on the same `payment-gateway-net` network from Issue 01. Verify this assumption when you run it; adjust only if it genuinely fails to resolve.

Create `dbt/payment_gateway/models/staging/stg_partner_transactions.yml`:

```yaml
version: 2

models:
  - name: stg_partner_transactions
    description: >
      Partner-side Transaction records, staged from the lake's silver zone.
      One row per Transaction ID (already deduplicated by the bronze-to-silver
      promotion step). No Bank-side data - that's Issue 03.
    columns:
      - name: transaction_id
        description: Gateway-assigned Transaction ID (CONTEXT.md).
      - name: partner_id
        description: The Partner that originated this transaction.
      - name: state
        description: Current lifecycle state - initiated/authorized/captured/settled/failed/refunded.
```

- [ ] **Step 4: Run dbt and verification**

Run:
```bash
set -a; source .env; set +a
cd dbt/payment_gateway
DBT_PROFILES_DIR=. dbt run --select stg_partner_transactions
cd ../..
./scripts/verify-stg-partner-transactions.sh
```

Expected: `PASS: stg_partner_transactions has 200 rows`

- [ ] **Step 5: Commit**

```bash
git add dbt/payment_gateway/models/staging/stg_partner_transactions.sql dbt/payment_gateway/models/staging/stg_partner_transactions.yml scripts/verify-stg-partner-transactions.sh
git commit -m "feat: add stg_partner_transactions dbt model (reads silver via ClickHouse s3())"
```

---

### Task 5: fct_transactions + fct_transactions_current

**Files:**
- Create: `dbt/payment_gateway/models/marts/fct_transactions.sql`
- Create: `dbt/payment_gateway/models/marts/fct_transactions_current.sql`
- Create: `scripts/verify-fct-transactions.sh`

**Interfaces:**
- Consumes: `stg_partner_transactions` (Task 4).
- Produces: `fct_transactions` (ClickHouse table, `ReplacingMergeTree`) and `fct_transactions_current` (ClickHouse view, deduplicated via `argMax()`). Issue 03 extends `fct_transactions` with a full outer join against a future `stg_bank_transactions`; Task 6 (Superset) reads from `fct_transactions_current`.

- [ ] **Step 1: Write the failing verification script**

Create `scripts/verify-fct-transactions.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking fct_transactions_current has rows, Bank-side columns null, no duplicate transaction_ids..."
RESULT=$(curl -sf "http://${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}@localhost:8124/" --data-binary @- <<'EOSQL'
SELECT
    count(*) AS total_rows,
    countIf(bank_id IS NOT NULL) AS non_null_bank_rows,
    count(*) - count(DISTINCT transaction_id) AS duplicate_transaction_ids
FROM fct_transactions_current
FORMAT TabSeparated
EOSQL
)

TOTAL=$(echo "$RESULT" | cut -f1)
BANK_NON_NULL=$(echo "$RESULT" | cut -f2)
DUPES=$(echo "$RESULT" | cut -f3)

if [ "${TOTAL:-0}" -lt 1 ]; then
  echo "FAIL: fct_transactions_current has no rows"
  exit 1
fi
if [ "${BANK_NON_NULL:-1}" -ne 0 ]; then
  echo "FAIL: expected all bank_id values to be NULL in this slice, found ${BANK_NON_NULL} non-null"
  exit 1
fi
if [ "${DUPES:-1}" -ne 0 ]; then
  echo "FAIL: found ${DUPES} duplicate transaction_id(s) in fct_transactions_current - dedup view is broken"
  exit 1
fi

echo "PASS: fct_transactions_current has ${TOTAL} rows, no bank-side data, no duplicates"
```

Make it executable: `chmod +x scripts/verify-fct-transactions.sh`

- [ ] **Step 2: Run it to confirm it fails**

Run: `set -a; source .env; set +a; ./scripts/verify-fct-transactions.sh`
Expected: FAIL — `fct_transactions_current` doesn't exist yet.

- [ ] **Step 3: Write fct_transactions**

Create `dbt/payment_gateway/models/marts/fct_transactions.sql`:

```sql
{{
    config(
        materialized='table',
        engine="ReplacingMergeTree(updated_at)",
        order_by="(transaction_id)"
    )
}}

SELECT
    transaction_id,
    -- Partner side (populated in this slice)
    partner_id,
    amount_cents,
    currency,
    state,
    decline_reason,
    initiated_at,
    authorized_at,
    captured_at,
    settled_at,
    failed_at,
    refunded_at,
    -- Bank side: intentionally NULL until Issue 03 adds the reconciliation join (ADR-0012)
    CAST(NULL AS Nullable(String)) AS bank_id,
    CAST(NULL AS Nullable(DateTime)) AS bank_authorized_at,
    CAST(NULL AS Nullable(DateTime)) AS bank_captured_at,
    CAST(NULL AS Nullable(DateTime)) AS bank_settled_at,
    updated_at
FROM {{ ref('stg_partner_transactions') }}
```

Create `dbt/payment_gateway/models/marts/fct_transactions_current.sql`:

```sql
{{ config(materialized='view') }}

SELECT
    transaction_id,
    argMax(partner_id, updated_at)      AS partner_id,
    argMax(amount_cents, updated_at)    AS amount_cents,
    argMax(currency, updated_at)        AS currency,
    argMax(state, updated_at)           AS state,
    argMax(decline_reason, updated_at)  AS decline_reason,
    argMax(initiated_at, updated_at)    AS initiated_at,
    argMax(authorized_at, updated_at)   AS authorized_at,
    argMax(captured_at, updated_at)     AS captured_at,
    argMax(settled_at, updated_at)      AS settled_at,
    argMax(failed_at, updated_at)       AS failed_at,
    argMax(refunded_at, updated_at)     AS refunded_at,
    argMax(bank_id, updated_at)         AS bank_id,
    argMax(bank_authorized_at, updated_at) AS bank_authorized_at,
    argMax(bank_captured_at, updated_at)   AS bank_captured_at,
    argMax(bank_settled_at, updated_at)    AS bank_settled_at,
    max(updated_at)                     AS updated_at
FROM {{ ref('fct_transactions') }}
GROUP BY transaction_id
```

- [ ] **Step 4: Run dbt and verification**

Run:
```bash
set -a; source .env; set +a
cd dbt/payment_gateway
DBT_PROFILES_DIR=. dbt run --select fct_transactions fct_transactions_current
cd ../..
./scripts/verify-fct-transactions.sh
```

Expected: `PASS: fct_transactions_current has 200 rows, no bank-side data, no duplicates`

- [ ] **Step 5: Commit**

```bash
git add dbt/payment_gateway/models/marts/fct_transactions.sql dbt/payment_gateway/models/marts/fct_transactions_current.sql scripts/verify-fct-transactions.sh
git commit -m "feat: add fct_transactions (ReplacingMergeTree) and fct_transactions_current dedup view"
```

---

### Task 6: Superset chart — transaction volume by day

**Files:**
- Modify: `superset/Dockerfile` (add ClickHouse SQLAlchemy driver)
- Create: `scripts/configure-superset-clickhouse.sh`
- Create: `scripts/verify-superset-chart.sh`

**Interfaces:**
- Consumes: `fct_transactions_current` (Task 5) via a ClickHouse SQLAlchemy connection from Superset.
- Produces: a Superset chart titled "Transaction Volume by Day" (daily count of transactions from `fct_transactions_current`, grouped by `toDate(initiated_at)`), on a dashboard reachable via Superset's UI/API.

- [ ] **Step 1: Write the failing verification script**

Create `scripts/verify-superset-chart.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

echo "Checking a chart named 'Transaction Volume by Day' exists in Superset..."
# Superset's REST API requires a login (access token) + CSRF token first; see
# scripts/configure-superset-clickhouse.sh for the auth flow this reuses.
source scripts/superset-auth.sh  # expected to export SUPERSET_ACCESS_TOKEN

CHART_COUNT=$(curl -sf -H "Authorization: Bearer ${SUPERSET_ACCESS_TOKEN}" \
  "http://localhost:8088/api/v1/chart/?q=(filters:!((col:slice_name,opr:eq,value:'Transaction Volume by Day')))" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")

if [ "${CHART_COUNT:-0}" -lt 1 ]; then
  echo "FAIL: no chart named 'Transaction Volume by Day' found"
  exit 1
fi

echo "PASS: found the Transaction Volume by Day chart in Superset"
```

Make it executable: `chmod +x scripts/verify-superset-chart.sh`

- [ ] **Step 2: Run it to confirm it fails**

Run: `set -a; source .env; set +a; ./scripts/verify-superset-chart.sh`
Expected: FAIL — no such chart exists, and/or the auth helper doesn't exist yet.

- [ ] **Step 3: Add the ClickHouse driver to Superset's image**

Modify `superset/Dockerfile` — read its current content first (from Issue 01, it already adds `psycopg2-binary` for Superset's own Postgres metadata store). Add a ClickHouse SQLAlchemy driver alongside it, e.g. `clickhouse-connect` (which registers the `clickhousedb://` SQLAlchemy dialect) — pin a specific version the same way `psycopg2-binary` is pinned in the existing file.

- [ ] **Step 4: Write the Superset auth helper and configuration script**

Create `scripts/superset-auth.sh` (a small reusable snippet, not a standalone executable — sourced by other scripts):

```bash
# Sourced, not executed directly. Logs into Superset's API and exports
# SUPERSET_ACCESS_TOKEN for subsequent authenticated requests.
SUPERSET_ACCESS_TOKEN=$(curl -sf -X POST "http://localhost:8088/api/v1/security/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${SUPERSET_ADMIN_USER}\", \"password\": \"${SUPERSET_ADMIN_PASSWORD}\", \"provider\": \"db\", \"refresh\": true}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
export SUPERSET_ACCESS_TOKEN
```

Create `scripts/configure-superset-clickhouse.sh`, which must, against the real running (rebuilt, per Step 3) Superset instance, using Superset's REST API (auth via `scripts/superset-auth.sh`, and note Superset's write endpoints also require a CSRF token fetched via `GET /api/v1/security/csrf_token/` with the bearer token, sent back as an `X-CSRFToken` header — discover the exact current requirement against the real instance rather than assuming):

1. Create (or find existing, idempotently) a **Database** connection to ClickHouse using the driver added in Step 3, SQLAlchemy URI form similar to `clickhousedb://{user}:{password}@clickhouse:8123/default` (verify the exact URI scheme `clickhouse-connect` expects — it may differ slightly; check the driver's own documentation/error messages if the first attempt is rejected). Note: from inside the Superset container, the ClickHouse host is `clickhouse` (Compose service name) on port `8123` (container-internal port — not the host-remapped `8124` from Issue 01's port-conflict fix, since Superset and ClickHouse talk over the Compose network, not through the host's remapped port).
2. Create (or find existing) a **Dataset** from `fct_transactions_current`.
3. Create (or find existing) a **Chart**: `slice_name` = `"Transaction Volume by Day"`, `viz_type` = a time-series/bar chart, query = daily count grouped by `initiated_at` truncated to day.
4. Create (or find existing) a **Dashboard** containing that chart.

Make both scripts executable: `chmod +x scripts/superset-auth.sh scripts/configure-superset-clickhouse.sh` (note: `superset-auth.sh` is sourced, not run directly, but still needs the execute bit per this repo's convention for scripts in `scripts/`).

- [ ] **Step 5: Rebuild Superset, run the configuration, and verify**

Run:
```bash
set -a; source .env; set +a
docker compose build superset superset-init
docker compose up -d superset-init
docker compose up -d superset
./scripts/configure-superset-clickhouse.sh
./scripts/verify-superset-chart.sh
```

Expected: `PASS: found the Transaction Volume by Day chart in Superset`

- [ ] **Step 6: Commit**

```bash
git add superset/Dockerfile scripts/superset-auth.sh scripts/configure-superset-clickhouse.sh scripts/verify-superset-chart.sh
git commit -m "feat: add ClickHouse driver to Superset and configure the first dashboard chart"
```

---

### Task 7: End-to-end walking-skeleton verification

**Files:**
- Create: `scripts/verify-walking-skeleton.sh`

**Interfaces:**
- Consumes: every script from Tasks 1-6.
- Produces: a single command proving Issue 02's full acceptance criteria in one run.

- [ ] **Step 1: Write the combined verification script**

Create `scripts/verify-walking-skeleton.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Rendering fresh .env from Vault ==="
./scripts/render-env-from-vault.sh
set -a; source .env; set +a

echo "=== Seeding mock Partner transactions ==="
python3 mock/generate_partner_transactions.py
./scripts/verify-mock-generator.sh

echo "=== Syncing Airbyte Postgres -> MinIO bronze ==="
./scripts/configure-airbyte-partner-source.sh
./scripts/verify-airbyte-bronze-sync.sh

echo "=== Promoting bronze -> silver ==="
python3 scripts/promote-bronze-to-silver.py
./scripts/verify-silver-promotion.sh

echo "=== Running dbt models ==="
cd dbt/payment_gateway
DBT_PROFILES_DIR=. dbt run
cd ../..
./scripts/verify-stg-partner-transactions.sh
./scripts/verify-fct-transactions.sh

echo "=== Verifying Superset chart ==="
./scripts/verify-superset-chart.sh

echo ""
echo "=== WALKING SKELETON COMPLETE: generator -> Airbyte -> lake -> dbt -> ClickHouse -> Superset ==="
```

Make it executable: `chmod +x scripts/verify-walking-skeleton.sh`

- [ ] **Step 2: Run the full verification**

Run: `./scripts/verify-walking-skeleton.sh`
Expected: every `PASS:` line printed, ending with `WALKING SKELETON COMPLETE`

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-walking-skeleton.sh
git commit -m "feat: add end-to-end walking-skeleton verification"
```

---

## Self-Review Notes

- **Spec coverage:** Task 1 covers the mock generator acceptance criterion; Task 2 covers Airbyte bronze sync; Task 3 covers the silver promotion ("a cleaning step promotes it to silver"); Task 4 covers the dbt staging model; Task 5 covers `fct_transactions`/`fct_transactions_current` (ReplacingMergeTree + dedup view, Bank-side null); Task 6 covers the Superset chart; Task 7 covers "demoable in one run." Every line of Issue 02's acceptance criteria maps to a task.
- **Known real risk, flagged deliberately:** Tasks 2 and 6 depend on discovering exact API shapes (Airbyte's REST API version, Superset's auth/CSRF flow) against the real running instances rather than a spec I can verify in advance — same category of risk Issue 01's Task 6 (Airbyte install) succeeded at by adapting to real observed behavior. Both tasks explicitly permit escalation (BLOCKED) if the underlying network path or API genuinely doesn't work as assumed, rather than silently faking success.
- **Type/name consistency:** `transaction_id`, `partner_id`, `state`, `decline_reason`, and the six timestamp columns are used identically across Tasks 1, 3, 4, and 5 — verified no renaming drift between the Postgres schema, the silver Parquet, the staging model, and the fact table.
