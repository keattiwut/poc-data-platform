# The apache/superset:4.1.1 base image ships without a PostgreSQL driver
# (only whatever DB drivers Superset's own extras pull in by default, which
# does not include psycopg2). Since Task 2's `superset` database lives in
# our Postgres container, we need psycopg2-binary to actually connect to it
# — see superset_config.py in this directory for the other half of this fix
# (the config file that reads DATABASE_* env vars into SQLALCHEMY_DATABASE_URI).
FROM apache/superset:4.1.1

USER root
RUN pip install --no-cache-dir psycopg2-binary==2.9.10
USER superset
