#!/usr/bin/env python3
"""Full mock data generator (Issue 05 / ADR-0010): seeds correlated
Partner-side and Bank-side Transaction records across the three transport
channels (Postgres inserts, SFTP CSV drops, Kafka messages), one simulated
day at a time.

Modes (all append-only; reset is a separate opt-in DAG, see
airflow/dags/reset_mock_data.py):

    generate_transactions.py                     # one batch for today
    generate_transactions.py --day 2026-07-01    # one batch for that day
    generate_transactions.py --day D --backfill-if-empty
        # first run: MOCK_BACKFILL_DAYS ending at D; later runs: just D
    generate_transactions.py --backfill          # unconditional backfill
        # (used by the reset_mock_data DAG after wiping everything)

Catalog: a fixed set of 4 Banks and 6 Partners, each with a stable profile
(integration channel, base authorization rate, decline-reason mix, volume
weight) held consistent across simulated days, so the per-entity comparison
charts show persistent, distinct behavior. Fee schedules live in the dbt seed
(dbt/payment_gateway/seeds/fee_schedule.csv), which covers every
partner x bank pair in this catalog.

Anomalies (configurable, so the dbt tests / freshness checks / alerting of
later issues have something real to catch):
    MOCK_ORPHAN_RATE        (default 0.10) one side's row never written
    MOCK_DUPLICATE_RATE     (default 0.02) duplicate Transaction IDs on the
                            SFTP/Kafka channels (Postgres PK would swallow
                            them; a re-sent file / re-produced message is the
                            realistic duplicate vector anyway)
    MOCK_MISSING_FILE_RATE  (default 0.05) an SFTP file drop silently never
                            happens for a day (its rows are lost - that is
                            the point; freshness checks should notice)

Volume: MOCK_DAILY_TRANSACTION_COUNT (default 1500) per simulated day,
MOCK_BACKFILL_DAYS (default 45) days of history on first run / reset.
"""
import argparse
import csv
import json
import os
import random
import uuid
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

import paramiko
import psycopg2
from kafka import KafkaProducer

DAILY_COUNT = int(os.environ.get("MOCK_DAILY_TRANSACTION_COUNT", "1500"))
BACKFILL_DAYS = int(os.environ.get("MOCK_BACKFILL_DAYS", "45"))
ORPHAN_RATE = float(os.environ.get("MOCK_ORPHAN_RATE", "0.10"))
DUPLICATE_RATE = float(os.environ.get("MOCK_DUPLICATE_RATE", "0.02"))
MISSING_FILE_RATE = float(os.environ.get("MOCK_MISSING_FILE_RATE", "0.05"))

# --- Catalog (ADR-0010): stable per-entity profiles --------------------------
# Each Partner/Bank has ONE stable integration channel (a real institution
# doesn't switch integration methods transaction-by-transaction), covering the
# PRD's source types (database, CSV-via-SFTP, Kafka). Profiles are constants
# so every simulated day reflects the same entity behavior; fee schedules for
# every pair live in the dbt seed.
PARTNERS = {
    #                 channel     volume  base auth  settle rate
    #                             weight  rate       given auth
    "partner_acme":     {"channel": "postgres", "weight": 3.0, "auth_rate": 0.94, "settle_rate": 0.97},
    "partner_globex":   {"channel": "sftp",     "weight": 2.0, "auth_rate": 0.90, "settle_rate": 0.95},
    "partner_initech":  {"channel": "kafka",    "weight": 2.0, "auth_rate": 0.86, "settle_rate": 0.93},
    "partner_umbrella": {"channel": "postgres", "weight": 1.0, "auth_rate": 0.80, "settle_rate": 0.90},
    "partner_wonka":    {"channel": "sftp",     "weight": 1.5, "auth_rate": 0.92, "settle_rate": 0.96},
    "partner_stark":    {"channel": "kafka",    "weight": 3.0, "auth_rate": 0.95, "settle_rate": 0.98},
}
BANKS = {
    # auth_modifier shifts the partner's base auth rate; decline_mix are
    # relative weights for the decline reasons this bank tends to give.
    "bank_chase": {
        "channel": "postgres", "auth_modifier": +0.02,
        "decline_mix": {"insufficient_funds": 45, "fraud_suspected": 15, "technical_error": 25, "invalid_account": 15},
    },
    "bank_wells_fargo": {
        "channel": "sftp", "auth_modifier": 0.00,
        "decline_mix": {"insufficient_funds": 55, "fraud_suspected": 10, "technical_error": 15, "invalid_account": 20},
    },
    "bank_citibank": {
        "channel": "kafka", "auth_modifier": -0.02,
        "decline_mix": {"insufficient_funds": 35, "fraud_suspected": 30, "technical_error": 20, "invalid_account": 15},
    },
    "bank_goldman": {
        "channel": "postgres", "auth_modifier": -0.04,
        "decline_mix": {"insufficient_funds": 30, "fraud_suspected": 20, "technical_error": 35, "invalid_account": 15},
    },
}

PARTNER_IDS = list(PARTNERS)
PARTNER_WEIGHTS = [p["weight"] for p in PARTNERS.values()]
BANK_IDS = list(BANKS)

PARTNER_COLUMNS = (
    "transaction_id", "partner_id", "bank_id", "amount_cents", "currency", "state",
    "decline_reason", "initiated_at", "authorized_at", "captured_at",
    "settled_at", "failed_at", "refunded_at", "updated_at",
)
BANK_COLUMNS = (
    "transaction_id", "partner_id", "bank_id", "amount_cents", "currency", "state",
    "decline_reason", "authorized_at", "captured_at", "settled_at", "failed_at",
    "refunded_at", "updated_at",
)


def random_timestamp_on(day: date) -> datetime:
    """A random moment within the given simulated day (UTC)."""
    midnight = datetime.combine(day, time.min, tzinfo=timezone.utc)
    return midnight + timedelta(seconds=random.randint(0, 86_399))


def build_transaction(day: date) -> dict:
    """Computes one shared lifecycle outcome from the entity profiles; both
    the partner and bank rows are derived from it so they stay correlated
    (same transaction_id, same real-world outcome, timestamps a few seconds
    apart to look independently recorded)."""
    partner_id = random.choices(PARTNER_IDS, weights=PARTNER_WEIGHTS)[0]
    bank_id = random.choice(BANK_IDS)
    partner = PARTNERS[partner_id]
    bank = BANKS[bank_id]
    initiated_at = random_timestamp_on(day)

    outcome = {
        "transaction_id": str(uuid.uuid4()),
        "partner_id": partner_id,
        "bank_id": bank_id,
        "amount_cents": random.randint(500, 250_000),
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

    def declined():
        reasons = bank["decline_mix"]
        return random.choices(list(reasons), weights=list(reasons.values()))[0]

    auth_rate = min(0.99, max(0.50, partner["auth_rate"] + bank["auth_modifier"]))
    if random.random() < auth_rate:
        authorized_at = initiated_at + timedelta(seconds=random.randint(1, 30))
        outcome["authorized_at"] = authorized_at
        outcome["state"] = "authorized"

        if random.random() < partner["settle_rate"]:
            captured_at = authorized_at + timedelta(seconds=random.randint(1, 60))
            outcome["captured_at"] = captured_at
            outcome["settled_at"] = captured_at + timedelta(minutes=random.randint(1, 120))
            outcome["state"] = "settled"
        else:
            outcome["failed_at"] = authorized_at + timedelta(seconds=random.randint(1, 60))
            outcome["state"] = "failed"
            outcome["decline_reason"] = declined()
    else:
        outcome["failed_at"] = initiated_at + timedelta(seconds=random.randint(1, 30))
        outcome["state"] = "failed"
        outcome["decline_reason"] = declined()

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
    return {k: outcome[k] for k in PARTNER_COLUMNS}


def to_bank_row(outcome: dict) -> dict:
    """The Bank doesn't see 'initiated' (that's Partner-only) - its state
    vocabulary starts at authorized. A transaction declined before
    authorization on the partner side still has a bank record (state=failed,
    decline_reason set), since the Bank is the one making that decision.
    build_transaction() always overwrites 'initiated' before returning, so it
    can never reach here."""
    delta = random.randint(0, 5)
    return {
        "transaction_id": outcome["transaction_id"],
        "partner_id": outcome["partner_id"],
        "bank_id": outcome["bank_id"],
        "amount_cents": outcome["amount_cents"],
        "currency": outcome["currency"],
        "state": outcome["state"],
        "decline_reason": outcome["decline_reason"],
        "authorized_at": shift(outcome["authorized_at"], delta),
        "captured_at": shift(outcome["captured_at"], delta),
        "settled_at": shift(outcome["settled_at"], delta),
        "failed_at": shift(outcome["failed_at"], delta),
        "refunded_at": shift(outcome["refunded_at"], delta),
        "updated_at": shift(outcome["updated_at"], delta),
    }


def insert_row(cur, table: str, columns: tuple, row: dict) -> None:
    placeholders = ", ".join(f"%({c})s" for c in columns)
    cur.execute(
        f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({placeholders})"
        " ON CONFLICT (transaction_id) DO NOTHING",
        row,
    )


def serialize_for_transport(row: dict) -> dict:
    """CSV and JSON can't natively hold datetime objects (unlike psycopg2's
    Postgres driver, which accepts them directly) - convert to ISO8601
    strings for the SFTP/Kafka channels."""
    return {k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in row.items()}


def inject_duplicates(rows: list) -> int:
    """Duplicate Transaction IDs anomaly: re-emit a small fraction of rows
    with the same transaction_id and a slightly later updated_at (a re-sent
    file / re-produced message), so the silver dedup has real work to do and
    later uniqueness tests have something to catch upstream of it."""
    dupes = [dict(r, updated_at=r["updated_at"] + timedelta(seconds=1))
             for r in rows if random.random() < DUPLICATE_RATE]
    rows.extend(dupes)
    return len(dupes)


def write_sftp_csv(sftp, rows: list, columns: tuple, remote_filename: str) -> None:
    if not rows:
        return
    # Missing-file anomaly: the drop silently never happens; these rows are
    # lost. That is deliberate - freshness checks should notice the gap.
    if random.random() < MISSING_FILE_RATE:
        print(f"ANOMALY: skipping SFTP drop of {remote_filename} ({len(rows)} rows lost)")
        return
    with sftp.open(f"upload/{remote_filename}", "w") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow(serialize_for_transport(row))
    print(f"Wrote {len(rows)} rows to SFTP upload/{remote_filename}")


def produce_kafka_messages(producer, rows: list, topic: str) -> None:
    for row in rows:
        producer.send(topic, serialize_for_transport(row))
    producer.flush()
    if rows:
        print(f"Produced {len(rows)} messages to Kafka topic '{topic}'")


def generate_day(cur, sftp, producer, day: date, count: int) -> dict:
    buffers = {("partner", "sftp"): [], ("partner", "kafka"): [],
               ("bank", "sftp"): [], ("bank", "kafka"): []}
    written = {"partner": {"postgres": 0, "sftp": 0, "kafka": 0},
               "bank": {"postgres": 0, "sftp": 0, "kafka": 0}}

    for _ in range(count):
        outcome = build_transaction(day)
        # Orphan anomaly: one side's row never gets written anywhere.
        roll = random.random()
        sides = []
        if not (roll < ORPHAN_RATE / 2):
            sides.append(("partner", to_partner_row(outcome), "partner_transactions", PARTNER_COLUMNS))
        if not (ORPHAN_RATE / 2 <= roll < ORPHAN_RATE):
            sides.append(("bank", to_bank_row(outcome), "bank_transactions", BANK_COLUMNS))

        for side, row, table, columns in sides:
            entity = PARTNERS[outcome["partner_id"]] if side == "partner" else BANKS[outcome["bank_id"]]
            channel = entity["channel"]
            if channel == "postgres":
                insert_row(cur, table, columns, row)
            else:
                buffers[(side, channel)].append(row)
            written[side][channel] += 1

    dupes = sum(inject_duplicates(rows) for rows in buffers.values())

    # Simulated day + real emission time in the name: day-partitioned like a
    # real drop, but a same-day re-run appends a new file instead of
    # clobbering the earlier one (append-only default).
    stamp = f"{day.strftime('%Y%m%d')}_{datetime.now(timezone.utc).strftime('%H%M%S%f')}"
    write_sftp_csv(sftp, buffers[("partner", "sftp")], PARTNER_COLUMNS,
                   f"partner_transactions_{stamp}.csv")
    write_sftp_csv(sftp, buffers[("bank", "sftp")], BANK_COLUMNS,
                   f"bank_transactions_{stamp}.csv")
    produce_kafka_messages(producer, buffers[("partner", "kafka")], "partner-transactions")
    produce_kafka_messages(producer, buffers[("bank", "kafka")], "bank-transactions")

    print(f"Day {day}: {count} transactions, partner={written['partner']}, "
          f"bank={written['bank']}, duplicates={dupes}")
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--day", type=date.fromisoformat, default=date.today(),
                        help="simulated day to generate (default: today)")
    parser.add_argument("--backfill", action="store_true",
                        help=f"generate MOCK_BACKFILL_DAYS ({BACKFILL_DAYS}) days ending at --day")
    parser.add_argument("--backfill-if-empty", action="store_true",
                        help="backfill only when partner_transactions is empty, else just --day")
    args = parser.parse_args()

    # .env's POSTGRES_HOST/SFTP_HOST are Docker Compose service names,
    # correct for container-to-container traffic but unreachable from the
    # host. Running this script directly on the host: override at
    # invocation time, e.g.
    # POSTGRES_HOST=localhost SFTP_HOST=localhost SFTP_PORT=12222 \
    #   KAFKA_BOOTSTRAP_SERVERS=localhost:9094 \
    #   python3 mock/generate_transactions.py
    conn = psycopg2.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        dbname="pipeline",
    )
    transport = paramiko.Transport((os.environ["SFTP_HOST"], int(os.environ.get("SFTP_PORT", "22"))))
    transport.connect(username=os.environ["SFTP_USER"], password=os.environ["SFTP_PASSWORD"])
    sftp = paramiko.SFTPClient.from_transport(transport)
    producer = KafkaProducer(
        bootstrap_servers=os.environ["KAFKA_BOOTSTRAP_SERVERS"],
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
    )
    try:
        with conn.cursor() as cur:
            cur.execute((Path(__file__).parent / "schema.sql").read_text())

            backfill = args.backfill
            if args.backfill_if_empty:
                cur.execute("SELECT EXISTS (SELECT 1 FROM partner_transactions)")
                backfill = not cur.fetchone()[0]
                if backfill:
                    print(f"partner_transactions is empty - first run, backfilling {BACKFILL_DAYS} days")

            days = ([args.day - timedelta(days=n) for n in range(BACKFILL_DAYS - 1, -1, -1)]
                    if backfill else [args.day])
            for day in days:
                generate_day(cur, sftp, producer, day, DAILY_COUNT)
        conn.commit()
        print(f"Generated {len(days)} day(s) x {DAILY_COUNT} transactions "
              f"({len(days) * DAILY_COUNT} total), ending {days[-1]}")
    finally:
        producer.close()
        sftp.close()
        transport.close()
        conn.close()


if __name__ == "__main__":
    main()
