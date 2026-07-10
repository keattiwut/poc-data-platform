# Vault file storage backend instead of dev mode

**Status: Proposed** (from 2026-07-09 project review — see `review_recommendation.md`)

Vault currently runs in dev mode ([ADR-0006](./0006-hashicorp-vault-for-secrets.md)), which means in-memory storage: any container restart wipes every secret, and — as the README documents at length — the only safe recovery is `docker compose down -v`, destroying **all data volumes** in the stack because re-seeded random passwords won't match credentials already baked into the Postgres/MinIO/ClickHouse volumes. The most destructive failure mode in the platform is triggered by the most mundane event (a container restart).

Switch Vault to server mode with the `file` storage backend on a Docker volume: a small HCL config, an init step that captures the unseal key and root token, and an unseal step on start. Secrets then survive restarts and the entire README hazard section (and its recover-by-wiping-everything procedure) disappears. Alternatives: keeping dev mode (rejected — the recovery procedure's blast radius grows with every issue that adds data worth keeping, e.g. the historical backfill in Issue 05); raft storage (rejected — built for HA clusters, overkill for one node); auto-unseal via a cloud KMS (rejected — violates [ADR-0002](./0002-self-hosted-oss-infrastructure.md)'s no-cloud constraint).

Consequence: bring-up gains an unseal step (scriptable in `verify-full-stack.sh`, with the unseal key stored operator-side like the current dev root token), `seed-secrets.sh`'s idempotency becomes trustworthy since "storage silently wiped" stops being a reachable state, and this closes most of the gap ADR-0006 deferred. Fits naturally into Issue 09 (security hardening).
