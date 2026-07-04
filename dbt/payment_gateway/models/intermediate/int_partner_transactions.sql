{{
    config(
        materialized='table',
        engine="MergeTree()",
        order_by="(tuple())"
    )
}}

-- Physical, on-disk copy of stg_partner_transactions (a view over the `s3()`
-- table function reading Parquet from MinIO). Verified against the running
-- instance (ClickHouse 24.10.4): joining stg_partner_transactions /
-- stg_bank_transactions directly - i.e. a JOIN whose right-hand side is
-- still the raw `s3()`-backed view, reading many columns - silently returns
-- NULL for an unpredictable subset of the joined-in columns even for rows
-- that plainly matched (e.g. `bank_id`, `decline_reason`,
-- `bank_decline_reason` came back all-NULL for otherwise-correct joins).
-- A `SELECT *` copy of the same view into a real MergeTree table, then
-- joining against *that* table instead, produces correct results every
-- time. `int_reconciled_transactions.sql` joins this table (and its bank
-- counterpart) rather than the staging views directly, to route around the
-- bug. No `order_by` semantics matter here - this is a disposable snapshot
-- purely to force materialization before the join.
SELECT * FROM {{ ref('stg_partner_transactions') }}
