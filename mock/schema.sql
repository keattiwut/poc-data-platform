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

-- Issue 03: partner_transactions already exists from Issue 02 without a
-- bank_id column. CREATE TABLE IF NOT EXISTS alone won't add a column to an
-- existing table, so this is an explicit, idempotent ALTER (safe to run
-- against both a fresh table and one that already has the column).
ALTER TABLE partner_transactions ADD COLUMN IF NOT EXISTS bank_id TEXT;

CREATE TABLE IF NOT EXISTS bank_transactions (
    transaction_id   TEXT PRIMARY KEY,
    partner_id       TEXT NOT NULL,
    bank_id          TEXT NOT NULL,
    amount_cents     BIGINT,
    currency         TEXT,
    state            TEXT NOT NULL,
    decline_reason   TEXT,
    authorized_at    TIMESTAMPTZ,
    captured_at      TIMESTAMPTZ,
    settled_at       TIMESTAMPTZ,
    failed_at        TIMESTAMPTZ,
    refunded_at      TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL
);
