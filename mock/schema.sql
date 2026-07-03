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
