{% test no_pan_like_values(model, column_name) %}
-- ADR-0015 backstop (Issue 09): fails if any value carries a standalone
-- 13-19 digit run - the shape of a raw PAN or full bank account number.
-- The extraction-layer guard (scripts/extract-to-bronze.py) rejects these
-- before the lake for the file/queue channels; this test covers every
-- channel at the warehouse.
SELECT {{ column_name }}
FROM {{ model }}
WHERE match(toString({{ column_name }}), '(^|[^0-9])[0-9]{13,19}([^0-9]|$)')
{% endtest %}
