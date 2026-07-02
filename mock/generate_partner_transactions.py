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
    # .env's POSTGRES_HOST is "postgres" (the Docker Compose service name),
    # correct for container-to-container traffic (e.g. Airflow's connection
    # string) but unreachable from the host. Running this script directly on
    # the host: override at invocation time, e.g. `POSTGRES_HOST=localhost
    # python3 mock/generate_partner_transactions.py` - postgres:5432 is
    # published to the host at localhost:5432 (docker-compose.yml).
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
