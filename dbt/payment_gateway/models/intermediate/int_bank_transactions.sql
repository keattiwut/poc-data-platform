{{
    config(
        materialized='table',
        engine="MergeTree()",
        order_by="(tuple())"
    )
}}

-- Physical, on-disk copy of stg_bank_transactions - see the header comment
-- in int_partner_transactions.sql for why this snapshot step exists (a real
-- ClickHouse 24.10.4 bug when JOINing directly against the `s3()`-backed
-- staging views).
SELECT * FROM {{ ref('stg_bank_transactions') }}
