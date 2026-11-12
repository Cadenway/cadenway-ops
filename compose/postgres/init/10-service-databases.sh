#!/bin/sh
# Creates one database and one user per service in the shared PostgreSQL.
#
# Run once by the image entrypoint, when the data volume is empty. Each service owns its database:
# nobody else reads or writes it. The passwords come from the environment (`<SERVICE>_DB_PASSWORD`),
# never from this file. A new service needs its line here and a manual `CREATE` on existing volumes.
#
# The entrypoint sources this file when it is not executable (bind mounts from Windows lose the
# bit): everything runs in a subshell so `set -eu` and `exit` never leak into the entrypoint.
(
  set -eu

  create_service_database() {
    service=$1
    password=$2

    if [ -z "$password" ]; then
      echo "postgres init: no password given for the \"$service\" database user." >&2
      exit 1
    fi

    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" \
      --set=service="$service" --set=password="$password" <<'SQL'
CREATE USER :"service" WITH PASSWORD :'password';
CREATE DATABASE :"service" OWNER :"service";
REVOKE ALL ON DATABASE :"service" FROM PUBLIC;
SQL
  }

  create_service_database identity "${IDENTITY_DB_PASSWORD:-}"
  create_service_database organization "${ORGANIZATION_DB_PASSWORD:-}"
  create_service_database billing "${BILLING_DB_PASSWORD:-}"
  create_service_database task "${TASK_DB_PASSWORD:-}"
  create_service_database document "${DOCUMENT_DB_PASSWORD:-}"
  create_service_database storage "${STORAGE_DB_PASSWORD:-}"
  create_service_database notification "${NOTIFICATION_DB_PASSWORD:-}"
  create_service_database automation "${AUTOMATION_DB_PASSWORD:-}"
  create_service_database integration "${INTEGRATION_DB_PASSWORD:-}"
  create_service_database search "${SEARCH_DB_PASSWORD:-}"
)
