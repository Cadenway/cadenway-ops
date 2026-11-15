#!/bin/sh
# Gives each service its database and its two roles in the shared PostgreSQL.
#
#   <service>_migrator  owns the database and everything in it; runs the migrations (DDL).
#   <service>_app       runs the service: it reads and writes rows, owns nothing, holds no DDL right
#                       and no BYPASSRLS, so the row-level security policies apply to it.
#
# Each service owns its database: nobody else connects to it. The passwords come from the
# environment (`<SERVICE>_DB_MIGRATOR_PASSWORD`, `<SERVICE>_DB_APP_PASSWORD`), never from this file,
# and reach psql through its environment, not through its arguments.
#
# Idempotent: every run creates what is missing, sets the passwords, the privileges and the
# timeouts again, and moves what a former single `<service>` role owned to the migrator before
# dropping that role. The image entrypoint runs it once, when the data volume is empty; on an
# existing volume, after a change here, a new service or a rotated password, run it by hand:
#
#   docker compose exec postgres sh /docker-entrypoint-initdb.d/10-service-databases.sh
#
# A new service needs its line at the end of this file. See docs/database.md.
#
# The entrypoint sources this file when it is not executable (bind mounts from Windows lose the
# bit): everything runs in a subshell so `set -eu` and `exit` never leak into the entrypoint.
(
  set -eu

  # The entrypoint exports POSTGRES_USER; a manual run inside the container may not have it.
  superuser=${POSTGRES_USER:-postgres}

  # Timeouts are set per role, not per query (cw-database-conventions of the services). A statement
  # of the application never outlives the 10 s budget of a request; a migration may build an index
  # for minutes, but gives up quickly on a lock, since a DDL statement waiting for one blocks every
  # query queued behind it.
  app_statement_timeout=10s
  app_lock_timeout=5s
  app_idle_in_transaction_timeout=30s
  migrator_statement_timeout=15min
  migrator_lock_timeout=5s
  migrator_idle_in_transaction_timeout=60s

  # Creates or updates the database and the two roles of one service.
  # Arguments: service name (also the database name), migrator password, application password.
  # Exits the subshell with an error when a password is missing or a statement fails.
  ensure_service_database() {
    service=$1
    migrator_password=$2
    app_password=$3

    if [ -z "$migrator_password" ] || [ -z "$app_password" ]; then
      echo "postgres init: a password of the \"$service\" database roles is missing." >&2
      exit 1
    fi

    # Cluster level: roles, database, who may connect.
    CW_MIGRATOR_PASSWORD=$migrator_password CW_APP_PASSWORD=$app_password \
      psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc --username "$superuser" --dbname postgres \
      --set=service="$service" \
      --set=app_statement_timeout="$app_statement_timeout" \
      --set=app_lock_timeout="$app_lock_timeout" \
      --set=app_idle_timeout="$app_idle_in_transaction_timeout" \
      --set=migrator_statement_timeout="$migrator_statement_timeout" \
      --set=migrator_lock_timeout="$migrator_lock_timeout" \
      --set=migrator_idle_timeout="$migrator_idle_in_transaction_timeout" <<'SQL'
\set migrator :service '_migrator'
\set app :service '_app'
\getenv migrator_password CW_MIGRATOR_PASSWORD
\getenv app_password CW_APP_PASSWORD

SELECT format('CREATE ROLE %I', :'migrator')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'migrator') \gexec
SELECT format('CREATE ROLE %I', :'app')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app') \gexec

ALTER ROLE :"migrator" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'migrator_password';
ALTER ROLE :"app" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'app_password';

ALTER ROLE :"migrator" SET statement_timeout = :'migrator_statement_timeout';
ALTER ROLE :"migrator" SET lock_timeout = :'migrator_lock_timeout';
ALTER ROLE :"migrator" SET idle_in_transaction_session_timeout = :'migrator_idle_timeout';
ALTER ROLE :"app" SET statement_timeout = :'app_statement_timeout';
ALTER ROLE :"app" SET lock_timeout = :'app_lock_timeout';
ALTER ROLE :"app" SET idle_in_transaction_session_timeout = :'app_idle_timeout';

SELECT format('CREATE DATABASE %I OWNER %I', :'service', :'migrator')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'service') \gexec
ALTER DATABASE :"service" OWNER TO :"migrator";

-- CONNECT only: no TEMPORARY, and CREATE (new schemas) stays with the owner.
REVOKE ALL ON DATABASE :"service" FROM PUBLIC;
REVOKE ALL ON DATABASE :"service" FROM :"app";
GRANT CONNECT ON DATABASE :"service" TO :"app";
SQL

    # Inside the database: what the application role may do with what the migrator creates.
    psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc --username "$superuser" --dbname "$service" \
      --set=service="$service" <<'SQL'
\set migrator :service '_migrator'
\set app :service '_app'

-- Volumes created before the two roles have one `<service>` role that owns everything.
SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = :'service') AS has_former_role \gset
\if :has_former_role
  REASSIGN OWNED BY :"service" TO :"migrator";
  DROP OWNED BY :"service";
  DROP ROLE :"service";
\endif

-- `public` belongs to the database owner; nobody else creates in it.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"app";

-- Rows, never structure: every schema, table and sequence the migrator creates from now on.
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" GRANT USAGE ON SCHEMAS TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator"
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" GRANT USAGE, SELECT ON SEQUENCES TO :"app";

-- And what already exists in `public`, on a volume older than the two roles.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app";
SQL
  }

  ensure_service_database identity \
    "${IDENTITY_DB_MIGRATOR_PASSWORD:-}" "${IDENTITY_DB_APP_PASSWORD:-}"
  ensure_service_database organization \
    "${ORGANIZATION_DB_MIGRATOR_PASSWORD:-}" "${ORGANIZATION_DB_APP_PASSWORD:-}"
  ensure_service_database billing \
    "${BILLING_DB_MIGRATOR_PASSWORD:-}" "${BILLING_DB_APP_PASSWORD:-}"
  ensure_service_database task \
    "${TASK_DB_MIGRATOR_PASSWORD:-}" "${TASK_DB_APP_PASSWORD:-}"
  ensure_service_database document \
    "${DOCUMENT_DB_MIGRATOR_PASSWORD:-}" "${DOCUMENT_DB_APP_PASSWORD:-}"
  ensure_service_database storage \
    "${STORAGE_DB_MIGRATOR_PASSWORD:-}" "${STORAGE_DB_APP_PASSWORD:-}"
  ensure_service_database notification \
    "${NOTIFICATION_DB_MIGRATOR_PASSWORD:-}" "${NOTIFICATION_DB_APP_PASSWORD:-}"
  ensure_service_database automation \
    "${AUTOMATION_DB_MIGRATOR_PASSWORD:-}" "${AUTOMATION_DB_APP_PASSWORD:-}"
  ensure_service_database integration \
    "${INTEGRATION_DB_MIGRATOR_PASSWORD:-}" "${INTEGRATION_DB_APP_PASSWORD:-}"
  ensure_service_database search \
    "${SEARCH_DB_MIGRATOR_PASSWORD:-}" "${SEARCH_DB_APP_PASSWORD:-}"
)
