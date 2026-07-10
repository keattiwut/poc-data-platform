# Replace Airbyte with dlt running as Airflow tasks (supersedes ADR-0020)

**Status: Accepted** (2026-07-10, by the maintainer, on the Issue 14 spike evidence below — including a verified prototype run and an observed Airbyte data-loss incident on a routine Docker restart). Supersedes [ADR-0020](./0020-airbyte-via-abctl.md) and amends the extraction row of [ADR-0004](./0004-core-oss-tool-stack.md). Migration is implemented by Issue 04 (new sources built on dlt; the existing Airbyte Partner/Bank-DB connectors rewritten as dlt tasks and the kind cluster retired there).

Airbyte is the heaviest component in the stack by a wide margin: `abctl` provisions an entire kind Kubernetes cluster to run it, it's the only service whose credentials sit outside Vault (an accepted gap, per the README), and it's the only service that can't be brought up, torn down, or reasoned about through `docker-compose.yml`. That cost buys a connector catalog — but this pipeline needs exactly four known, simple source types (Postgres, SFTP-dropped Excel/CSV, Kafka), and only one connector exists so far. Before Issue 04 invests in the remaining three, the trade is worth re-deciding.

The proposal: use dlt (data load tool — a plain Python library, not a platform) for extraction, with each source a small Python function running as an ordinary Airflow task. dlt has maintained sources for SQL databases, filesystem/SFTP (CSV and Excel), and Kafka, and writes Parquet to S3-compatible storage natively — exactly the bronze-zone contract Airbyte fills today. Consequences: the kind cluster, `abctl`, and `install-airbyte.sh` are deleted; extraction credentials come from the same Vault→`.env` render as everything else, closing the ADR-0006 coverage gap; extraction logic becomes code reviewed in this repo; and Airflow orchestrates extraction directly instead of triggering an external platform's API. The costs are real too: extraction bugs become ours to fix rather than a connector vendor's, and there's no UI for configuring sources (config lives in code — arguably a feature at this team size).

Alternatives: keeping Airbyte (status quo — right choice if the connector catalog will actually be exercised, e.g. many future heterogeneous sources; wrong-sized for four fixed ones); Meltano/Singer taps (same code-not-platform shape as dlt but an aging ecosystem with inconsistent tap quality); hand-rolled extractors (rejected by ADR-0004 for good reason — dlt is precisely the middle ground, standard schema-evolution/state handling without the platform). Decision trigger: make this call before starting Issue 04; the one existing Partner-DB connector is cheap to rewrite, three more make the status quo sticky.

## Evidence (Issue 14 spike, 2026-07-09)

### Source-by-source support matrix

| Need | dlt support | Maturity | Docs |
| --- | --- | --- | --- |
| Postgres (Partner/Bank DBs) | `sql_database` / `sql_table` — ships inside dlt core (`from dlt.sources.sql_database import sql_table`), Postgres explicitly supported via any SQLAlchemy dialect; `backend="pyarrow"` streams Arrow straight to Parquet (docs cite 20–30x vs the row normalizer); incremental loading built in. Install: `dlt[sql_database]` + pyarrow + psycopg2. | Core source | [sql_database](https://dlthub.com/docs/dlt-ecosystem/verified-sources/sql_database/), [configuration](https://dlthub.com/docs/dlt-ecosystem/verified-sources/sql_database/configuration) |
| SFTP-dropped CSV | `filesystem` source (`from dlt.sources.filesystem import filesystem`) with `bucket_url="sftp://host/path"` + built-in `read_csv()` reader; SFTP auth (password or SSH key) via `dlt[sftp]` (paramiko). | Core source; CSV/Parquet/JSONL readers native | [filesystem](https://dlthub.com/docs/dlt-ecosystem/verified-sources/filesystem/) |
| SFTP-dropped Excel | Same `filesystem` source, but **no native `read_excel`** — the docs show a ~10-line custom transformer using pandas/openpyxl. Small, documented, but it is our code. | Core source + documented custom transformer | [filesystem advanced](https://dlthub.com/docs/dlt-ecosystem/verified-sources/filesystem/advanced) |
| Kafka (drained as batch) | `kafka_consumer` resource on confluent-kafka; `batch_size`/`batch_timeout` and `start_from` timestamp; installed by copying via `dlt init kafka <dest>`. Fits ADR-0001's periodic-drain model. Docs carry a caveat about offsets on freshly created topics. | **Verified source** (template copied into the repo, not a core import) — the weakest square in the matrix | [kafka](https://dlthub.com/docs/dlt-ecosystem/verified-sources/kafka) |
| Parquet → MinIO bronze | `filesystem` **destination** (`dlt[filesystem]`, s3fs/botocore): S3-compatible via `endpoint_url` in credentials (MinIO pattern is first-class), `loader_file_format="parquet"`, and full layout control (`layout="{table_name}/{load_id}.{file_id}.{ext}"` + custom placeholders) — can reproduce the `bronze/<table>/` contract Airbyte writes today. | Core destination | [filesystem destination](https://dlthub.com/docs/dlt-ecosystem/destinations/filesystem), [env-var credential config](https://dlthub.com/docs/general-usage/credentials/setup) |

Verdict: every needed source/destination square is covered by dlt core except Kafka (verified-source tier, copied into the repo — i.e., code we own and review, which is exactly the shape this ADR proposes anyway) and Excel (documented custom transformer, ~10 lines).

### Prototype

`scripts/spike-dlt-partner-extraction.py` — `partner_transactions` from the mock Postgres to Parquet under `s3://data-lake/bronze-dlt/` (isolated from Airbyte's real `bronze/`). **Verified 2026-07-10 against the running stack**: first execution succeeded unmodified — 196 rows extracted to Parquet on MinIO, load step 0.37s (dlt's output: a 21 KiB parquet file vs the ~5 MiB Airbyte writes for the same rows). The whole thing is ~45 lines of code against the ~290-line bash/REST/abctl choreography of `scripts/configure-airbyte-partner-source.sh` doing the same job. Also observed the same day, strengthening the operational-weight argument: the abctl kind cluster stores Airbyte's internal database on storage that did not survive a routine Docker engine restart — all sources/connections were lost and had to be rebuilt (bootloader re-run + reconfigure scripts), while every Compose-managed service kept its state on named volumes. Still open before full migration: a Kafka-drain smoke test (the thinnest matrix square).

### Operational weight

- **Footprint**: Airbyte-via-abctl = a kind Kubernetes cluster (multi-GB RAM: server, workers, temporal, webapp, its own Postgres) that `docker-compose.yml` cannot see, plus `abctl`/WSL2-only install and verify scripts. dlt = a pip dependency inside the Airflow image; extraction becomes ordinary Airflow tasks, torn up/down with the rest of the Compose stack.
- **Credential path**: Airbyte is the only credential domain outside Vault (accepted ADR-0006 gap) — secrets are pasted into its internal store via the REST API, and even reaching that API means scraping `abctl local credentials`. dlt reads the same Vault→`.env` render as every other service (env vars like `DESTINATION__FILESYSTEM__CREDENTIALS__AWS_ACCESS_KEY_ID`, or values passed in code), closing the gap.
- **Networking**: the kind cluster sits on a different Docker network, forcing the `host.docker.internal` bridge workaround documented in the configure scripts. dlt tasks run on `payment-gateway-net` and use Compose service names.
- **Upgrade story**: Airbyte = abctl/platform upgrades plus per-connector versions managed inside its catalog. dlt = a pinned pip version bumped in one requirements file, reviewed like any dependency.

### What is lost

- The Airbyte UI for configuring sources and inspecting sync history (config moves to reviewed code; sync history becomes Airflow task logs — arguably a wash at this team size, but a real loss for non-engineers).
- The ~400-connector catalog as a future option (this pipeline needs exactly four fixed source types).
- Vendor-maintained connector fixes: extraction bugs (Kafka offset edge cases, Excel parsing) become ours.

### Recommendation (spike author — not the final decision)

**Accept ADR-0024.** All four source types plus the bronze contract are covered, three of them by dlt core; the heaviest stack component and the only out-of-Vault credential domain are eliminated for the price of owning a copied Kafka source template and a small Excel transformer. Strongest counterargument: the prototype is unverified and the Kafka square is the thinnest — so run `scripts/spike-dlt-partner-extraction.py` against the live stack (and ideally a minimal Kafka-drain smoke test) before deleting anything Airbyte. Status is left **Proposed**; accepting is the maintainer's call.
