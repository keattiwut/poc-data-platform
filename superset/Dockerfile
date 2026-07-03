# The apache/superset:4.1.1 base image ships without a PostgreSQL driver
# (only whatever DB drivers Superset's own extras pull in by default, which
# does not include psycopg2). Since Task 2's `superset` database lives in
# our Postgres container, we need psycopg2-binary to actually connect to it
# — see superset_config.py in this directory for the other half of this fix
# (the config file that reads DATABASE_* env vars into SQLALCHEMY_DATABASE_URI).
#
# clickhouse-connect registers the `clickhousedb://` SQLAlchemy dialect
# (entry points `sqlalchemy.dialects:clickhousedb` /
# `clickhousedb.connect`, verified via the package's own entry_points.txt).
# This is a separate concern from the psycopg2 driver above: psycopg2 lets
# Superset talk to its own Postgres metadata store, while clickhouse-connect
# lets Superset query ClickHouse as a *data source* (Task 6, fct_transactions_current).
# It depends on sqlalchemy>=1.4.40,<3.0 for its dialect support, which the
# base image's pinned sqlalchemy 1.4.52 already satisfies.
FROM apache/superset:4.1.1

USER root
RUN pip install --no-cache-dir psycopg2-binary==2.9.10 clickhouse-connect==1.4.1
USER superset
