{{ config(materialized='table', engine='MergeTree()', order_by='(date_day)') }}

-- Conformed date dimension (ADR-0007, Issue 06): calendar attributes for
-- period comparisons (week/month/quarter/year). Fixed three-year range
-- starting well before any mock backfill window; extend the range when the
-- POC outlives it.
SELECT
    toYYYYMMDD(date_day)          AS date_key,
    date_day,
    toDayOfWeek(date_day)         AS day_of_week,
    toDayOfWeek(date_day) >= 6    AS is_weekend,
    toStartOfWeek(date_day, 1)    AS week_start,
    toISOWeek(date_day)           AS iso_week,
    toStartOfMonth(date_day)      AS month_start,
    toMonth(date_day)             AS month,
    toQuarter(date_day)           AS quarter,
    toYear(date_day)              AS year
FROM (
    SELECT toDate('2025-01-01') + number AS date_day
    FROM numbers(1096)
)
