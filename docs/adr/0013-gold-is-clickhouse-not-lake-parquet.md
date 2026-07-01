# Gold is the ClickHouse mart tables, not a lake Parquet zone

Amends [0003](./0003-parquet-medallion-lake.md). Bronze (raw) and silver (cleaned) remain Parquet zones on the lake (MinIO) — dbt staging models read from silver. But dbt's intermediate models (the Bank/Partner reconciliation join, fee denormalization) and marts models (`fct_transactions`, `dim_bank`, etc.) materialize directly as tables in ClickHouse, with no separate gold-zone Parquet output on the lake. ClickHouse's mart tables *are* gold.

This was chosen over writing a genuine gold Parquet zone before loading ClickHouse because ClickHouse is the actual query target for every downstream consumer (Superset) — an intermediate gold-Parquet copy would just be a second place for schema drift against ClickHouse to occur, for no consumer that currently needs lake-native access to fully curated data. Revisit if a future consumer other than ClickHouse needs to read the curated/gold layer directly.
