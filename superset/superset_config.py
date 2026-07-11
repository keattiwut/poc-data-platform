"""Superset configuration override, mounted into the image at
/app/pythonpath/superset_config.py.

The official apache/superset:4.1.1 image does NOT bake in logic to read the
DATABASE_DIALECT/DATABASE_USER/DATABASE_PASSWORD/DATABASE_HOST/DATABASE_PORT/
DATABASE_DB environment variables — that logic only lives in the upstream
source repo's docker/pythonpath_dev/superset_config.py, which is mounted in
by their docker-compose examples but is not part of the released image.
Without this file, Superset silently falls back to a local SQLite file
(/app/superset_home/superset.db) instead of the `superset` Postgres database
Task 2 created, and that SQLite state does not survive container
recreation. This file restores the intended behavior: build
SQLALCHEMY_DATABASE_URI from the same DATABASE_* env vars docker-compose.yml
already injects.

Superset auto-imports `superset_config` because /app/pythonpath is on
PYTHONPATH in the base image; this file just needs to be present there
(see the superset-init/superset volume mounts in docker-compose.yml).
"""
import os


def get_env_variable(var_name: str, default: str | None = None) -> str:
    value = os.environ.get(var_name, default)
    if value is None:
        raise EnvironmentError(f"The environment variable {var_name} was missing")
    return value


DATABASE_DIALECT = get_env_variable("DATABASE_DIALECT")
DATABASE_USER = get_env_variable("DATABASE_USER")
DATABASE_PASSWORD = get_env_variable("DATABASE_PASSWORD")
DATABASE_HOST = get_env_variable("DATABASE_HOST")
DATABASE_PORT = get_env_variable("DATABASE_PORT")
DATABASE_DB = get_env_variable("DATABASE_DB")

# sslmode=require: TLS to the metadata Postgres (Issue 09 / ADR-0017).
SQLALCHEMY_DATABASE_URI = (
    f"{DATABASE_DIALECT}://{DATABASE_USER}:{DATABASE_PASSWORD}"
    f"@{DATABASE_HOST}:{DATABASE_PORT}/{DATABASE_DB}?sslmode=require"
)

SECRET_KEY = get_env_variable("SUPERSET_SECRET_KEY")
