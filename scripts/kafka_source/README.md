# kafka_source: dlt `kafka` verified source, vendored

Copied verbatim (`__init__.py`, `helpers.py`, `requirements.txt`) from
dlt-hub/verified-sources `sources/kafka/` at commit
`3957506893a7da821dbcc6acd51c7ca4475d1f53` (2026-07-03), per ADR-0024 — the
Kafka square is verified-source tier, i.e. code copied into the repo and owned
here rather than imported from dlt core. Normally `dlt init kafka filesystem`
does this copy; it was done by hand (same files, same content) because the
host Python (3.14) predates dlt support.

Renamed from `kafka/` to `kafka_source/` so the import never collides with the
`kafka-python` package (`import kafka`) that `mock/generate_transactions.py`
uses.

Used by `scripts/extract-to-bronze.py` (the `kafka` channel).
