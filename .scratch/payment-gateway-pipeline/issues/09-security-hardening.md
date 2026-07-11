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

- [x] A validation guard rejects/flags fields resembling a raw PAN or full bank account number before they reach the lake
- [x] MinIO server-side encryption is enabled; ClickHouse data volumes are encrypted at rest
- [x] TLS is configured between every internal service, verified by inspecting actual traffic/config, not just assumed
- [x] Superset is reachable from outside the internal network with TLS, no default credentials, and login rate limiting in place
- [x] Airflow, Grafana, and the MinIO console are confirmed unreachable from outside the internal network
- [x] Each MinIO consumer (ClickHouse, dbt, promotion job, extraction) authenticates with its own least-privilege user; root credentials are used only for MinIO administration

## Blocked by

- 01-infra-bootstrap.md

## Comments

**2026-07-12 (agent):** Implemented on branch `issue-09-security-hardening`; every criterion demonstrated live by `scripts/verify-security.sh` plus a full green walking-skeleton over the hardened stack.

- **PAN guard (ADR-0015)**: extraction rejects any string field with a standalone 13–19 digit run (demonstrated: poisoned SFTP CSV with a 16-digit PAN fails the extract task naming the violation); `no_pan_like_values` dbt generic test backstops all channels.
- **At rest (ADR-0017)**: MinIO SSE-S3 via built-in KMS (Vault-seeded key; `mc stat` shows SSE-S3) and ClickHouse AES-256-CTR encrypted disk as the MergeTree default policy (all active parts on `encrypted_disk`). Gotchas: the implicit `default` disk can't be wrapped; pre-existing tables had to be dropped under a temporarily lifted policy default.
- **In transit (ADR-0017)**: local internal CA (`tls/`, git-ignored, `scripts/generate-tls-certs.sh`); Vault/MinIO/ClickHouse(8443)/Postgres serve TLS with every consumer CA-wired (dbt `secure`, ClickHouse `caConfig` for s3(), duckdb `ca_cert_file`, s3fs via `AWS_CA_BUNDLE`, `sslmode=require`, mc via mounted CA + pinned `MC_CONFIG_DIR`, Schannel curl shim for Git Bash). Documented ceilings: mock Kafka stays PLAINTEXT (outside ADR-0017's list; SFTP is SSH-encrypted), ClickHouse's 9363 metrics endpoint stays http.
- **Exposure (ADR-0016)**: all host ports bind `127.0.0.1` except the new nginx `superset-proxy` (`0.0.0.0:8443`, TLS, login rate-limit 10 r/m → 429, Vault-random creds). Side-fixes: Kafka advertises `127.0.0.1` (localhost→::1 vs IPv4-only bind) and got a named volume (its /tmp log dir previously died with the container, desyncing dlt offsets).
- **Least privilege (finding 7)**: `svc_extraction` (rw bronze), `svc_promotion` (ro bronze / rw silver), `svc_warehouse` (ro silver) created by minio-init from Vault; escalation attempts refused; root is admin-only.
- Also fixed en route: freshness task reordered after dbt_build (concurrent dbt processes collide on the ClickHouse session).
