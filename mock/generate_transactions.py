#!/usr/bin/env python3
"""Seeds mock Partner-side and Bank-side Transaction records into the
pipeline Postgres database, sharing a gateway-assigned Transaction ID.

Extends Issue 02's Partner-only generator (mock/generate_partner_transactions.py)
with a correlated Bank side (Issue 03) - still not the full ADR-0010 spec
(no Faker, no daily scheduling, no full anomaly catalog - that's Issue 05).
"""
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

import psycopg2

TRANSACTION_COUNT = int(os.environ.get("MOCK_TRANSACTION_COUNT", "200"))
PARTNER_IDS = ["partner_acme", "partner_globex", "partner_initech"]
BANK_IDS = ["bank_chase", "bank_wells_fargo", "bank_citibank"]
DECLINE_REASONS = ["insufficient_funds", "fraud_suspected", "technical_error", "invalid_account"]

# Roughly: 90% initiated->authorized, of those 95% ->captured->settled,
# 5% fail after authorization. 10% never even authorize (declined outright).
AUTH_RATE = 0.90
SETTLE_RATE_GIVEN_AUTH = 0.95

# Issue 03: ~10% of transactions have only ONE side's row written, to
# exercise fct_transactions's full outer join (ADR-0012) against real data
# rather than only via the join logic's own claimed correctness.
ORPHAN_RATE = 0.10


def random_timestamp_today() -> datetime:
    now = datetime.now(timezone.utc)
    seconds_ago = random.randint(0, 23 * 3600)
    return now - timedelta(seconds=seconds_ago)


def build_transaction() -> dict:
    """Computes one shared lifecycle outcome; both the partner and bank rows
    are derived from it so they stay correlated (same transaction_id, same
    real-world outcome, timestamps a few seconds apart to look independently
    recorded)."""
    transaction_id = str(uuid.uuid4())
    partner_id = random.choice(PARTNER_IDS)
    bank_id = random.choice(BANK_IDS)
    amount_cents = random.randint(500, 250_000)
    initiated_at = random_timestamp_today()

    outcome = {
        "transaction_id": transaction_id,
        "partner_id": partner_id,
        "bank_id": bank_id,
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
        outcome["authorized_at"] = authorized_at
        outcome["state"] = "authorized"

        if random.random() < SETTLE_RATE_GIVEN_AUTH:
            captured_at = authorized_at + timedelta(seconds=random.randint(1, 60))
            settled_at = captured_at + timedelta(minutes=random.randint(1, 120))
            outcome["captured_at"] = captured_at
            outcome["settled_at"] = settled_at
            outcome["state"] = "settled"
        else:
            failed_at = authorized_at + timedelta(seconds=random.randint(1, 60))
            outcome["failed_at"] = failed_at
            outcome["state"] = "failed"
            outcome["decline_reason"] = random.choice(DECLINE_REASONS)
    else:
        failed_at = initiated_at + timedelta(seconds=random.randint(1, 30))
        outcome["failed_at"] = failed_at
        outcome["state"] = "failed"
        outcome["decline_reason"] = random.choice(DECLINE_REASONS)

    outcome["updated_at"] = max(
        t for t in [
            outcome["initiated_at"], outcome["authorized_at"], outcome["captured_at"],
            outcome["settled_at"], outcome["failed_at"], outcome["refunded_at"],
        ] if t is not None
    )
    return outcome


def shift(ts, seconds):
    return ts + timedelta(seconds=seconds) if ts is not None else None


def to_partner_row(outcome: dict) -> dict:
    return {k: outcome[k] for k in (
        "transaction_id", "partner_id", "amount_cents", "currency", "state",
        "decline_reason", "initiated_at", "authorized_at", "captured_at",
        "settled_at", "failed_at", "refunded_at", "updated_at",
    )} | {"bank_id": outcome["bank_id"]}


def to_bank_row(outcome: dict) -> dict:
    """The Bank doesn't see 'initiated' (that's Partner-only) - its state
    vocabulary starts at authorized. A transaction declined before
    authorization on the partner side still has a bank record (state=failed,
    decline_reason set), since the Bank is the one making that decision."""
    delta = random.randint(0, 5)
    bank_state = outcome["state"] if outcome["state"] != "initiated" else "failed"
    return {
        "transaction_id": outcome["transaction_id"],
        "partner_id": outcome["partner_id"],
        "bank_id": outcome["bank_id"],
        "amount_cents": outcome["amount_cents"],
        "currency": outcome["currency"],
        "state": bank_state,
        "decline_reason": outcome["decline_reason"],
        "authorized_at": shift(outcome["authorized_at"], delta),
        "captured_at": shift(outcome["captured_at"], delta),
        "settled_at": shift(outcome["settled_at"], delta),
        "failed_at": shift(outcome["failed_at"], delta),
        "refunded_at": shift(outcome["refunded_at"], delta),
        "updated_at": shift(outcome["updated_at"], delta),
    }


def insert_partner_row(cur, row: dict) -> None:
    cur.execute(
        """
        INSERT INTO partner_transactions (
            transaction_id, partner_id, amount_cents, currency, state,
            decline_reason, initiated_at, authorized_at, captured_at,
            settled_at, failed_at, refunded_at, updated_at, bank_id
        ) VALUES (
            %(transaction_id)s, %(partner_id)s, %(amount_cents)s, %(currency)s, %(state)s,
            %(decline_reason)s, %(initiated_at)s, %(authorized_at)s, %(captured_at)s,
            %(settled_at)s, %(failed_at)s, %(refunded_at)s, %(updated_at)s, %(bank_id)s
        )
        ON CONFLICT (transaction_id) DO NOTHING
        """,
        row,
    )


def insert_bank_row(cur, row: dict) -> None:
    cur.execute(
        """
        INSERT INTO bank_transactions (
            transaction_id, partner_id, bank_id, amount_cents, currency, state,
            decline_reason, authorized_at, captured_at, settled_at, failed_at,
            refunded_at, updated_at
        ) VALUES (
            %(transaction_id)s, %(partner_id)s, %(bank_id)s, %(amount_cents)s, %(currency)s, %(state)s,
            %(decline_reason)s, %(authorized_at)s, %(captured_at)s, %(settled_at)s, %(failed_at)s,
            %(refunded_at)s, %(updated_at)s
        )
        ON CONFLICT (transaction_id) DO NOTHING
        """,
        row,
    )


def main() -> None:
    # .env's POSTGRES_HOST is "postgres" (the Docker Compose service name),
    # correct for container-to-container traffic but unreachable from the
    # host. Running this script directly on the host: override at invocation
    # time, e.g. `POSTGRES_HOST=localhost python3 mock/generate_transactions.py`
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

            partner_written = 0
            bank_written = 0
            for _ in range(TRANSACTION_COUNT):
                outcome = build_transaction()
                roll = random.random()
                write_partner = not (roll < ORPHAN_RATE / 2)
                write_bank = not (ORPHAN_RATE / 2 <= roll < ORPHAN_RATE)

                if write_partner:
                    insert_partner_row(cur, to_partner_row(outcome))
                    partner_written += 1
                if write_bank:
                    insert_bank_row(cur, to_bank_row(outcome))
                    bank_written += 1

        conn.commit()
        print(f"Seeded {partner_written} partner_transactions rows and {bank_written} bank_transactions rows "
              f"({TRANSACTION_COUNT} transactions total, orphan rate ~{ORPHAN_RATE:.0%}).")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
