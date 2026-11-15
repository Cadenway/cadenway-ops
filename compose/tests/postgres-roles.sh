#!/usr/bin/env bash
# End-to-end test of compose/postgres/init against the PostgreSQL of compose/infra.yaml, with the
# local values of compose/.env.example. Covers: the two roles of a service and their passwords, an
# application role that cannot change the structure, row-level security applied to it, a service
# kept out of the other databases, the timeouts of each role, a second run that changes nothing, a
# rotated password, and a volume created with the former single role brought up to date.
#
#   bash compose/tests/postgres-roles.sh
#
# It creates and removes the Compose project cadenway-test-postgres with its own volumes: it never
# touches the local stack, and must never run on a Cadenway host.
#
# The assertions are strings evaluated by `check`, so they expand late on purpose.
# shellcheck disable=SC2016
set -euo pipefail
# Git Bash would rewrite the container paths given to `docker compose exec`.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
readonly PROJECT=cadenway-test-postgres
readonly INIT=/docker-entrypoint-initdb.d/10-service-databases.sh

compose() { docker compose -p "$PROJECT" --env-file .env.example -f infra.yaml "$@"; }
cleanup() { compose down --volumes --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# Runs SQL as a role, as a service does: over the network name of the container, since the image
# trusts the loopback addresses without a password. Prints the rows, or the error on failure.
# Arguments: role, password, database; the SQL comes on stdin or as further psql arguments.
as() {
  local role=$1 password=$2 database=$3
  shift 3
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -tAq \
    "postgres://$role:$password@postgres:5432/$database" "$@" 2>&1
}
superuser() { compose exec -T postgres psql -v ON_ERROR_STOP=1 -tAq -U postgres "$@" 2>&1; }
run_init() { compose exec -T "$@" postgres sh "$INIT" 2>&1; }

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; echo "${OUT:-}" | tail -5; FAILED=1; fi; }
FAILED=0
OUT=''

compose up -d --wait postgres >/dev/null 2>&1

echo '=== 1. the migrator owns the database and changes its structure'
OUT=$(as task_migrator task_migrator task <<'SQL'
CREATE TABLE tasks (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  organization_id uuid NOT NULL,
  title text NOT NULL
);
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks FORCE ROW LEVEL SECURITY;
CREATE POLICY organization_isolation ON tasks USING (
  organization_id = nullif(current_setting('app.organization_id', true), '')::uuid
  OR current_setting('app.system_access', true) = 'on'
);
CREATE SCHEMA jobs;
CREATE TABLE jobs.queue (id bigserial PRIMARY KEY);
SQL
) || true
check 'migration applied' '[[ -z $OUT ]]'
OUT=$(superuser -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'task'")
check 'database owned by the migrator' '[[ $OUT == task_migrator ]]'

echo '=== 2. the application role reads and writes rows, never the structure'
OUT=$(as task_app task_app task <<'SQL'
BEGIN;
SET LOCAL app.organization_id = '018f0000-0000-7000-8000-000000000001';
INSERT INTO tasks (organization_id, title)
VALUES ('018f0000-0000-7000-8000-000000000001', 'CAD-482');
COMMIT;
INSERT INTO jobs.queue DEFAULT VALUES;
SQL
) || true
check 'rows written, in a schema created later too' '[[ -z $OUT ]]'
OUT=$(as task_app task_app task -c 'CREATE TABLE forbidden (id int)') || true
check 'CREATE TABLE refused' '[[ $OUT == *"permission denied for schema public"* ]]'
OUT=$(as task_app task_app task -c 'ALTER TABLE tasks ADD COLUMN forbidden int') || true
check 'ALTER TABLE refused' '[[ $OUT == *"must be owner of table tasks"* ]]'
OUT=$(as task_app task_app task -c 'DROP TABLE tasks') || true
check 'DROP TABLE refused' '[[ $OUT == *"must be owner of table tasks"* ]]'
OUT=$(as task_app task_app task -c 'TRUNCATE tasks') || true
check 'TRUNCATE refused' '[[ $OUT == *"permission denied for table tasks"* ]]'
OUT=$(as task_app task_app task -c 'CREATE SCHEMA forbidden') || true
check 'CREATE SCHEMA refused' '[[ $OUT == *"permission denied for database task"* ]]'
OUT=$(as task_app task_app task -c 'CREATE TEMPORARY TABLE forbidden (id int)') || true
check 'temporary table refused' '[[ $OUT == *"permission denied"* ]]'
OUT=$(as task_app task_app task -c 'ALTER TABLE tasks DISABLE ROW LEVEL SECURITY') || true
check 'row-level security cannot be switched off' '[[ $OUT == *"must be owner of table tasks"* ]]'

echo '=== 3. row-level security applies to the application role'
OUT=$(as task_app task_app task -c 'SELECT count(*) FROM tasks')
check 'no organization set: no row' '[[ $OUT == 0 ]]'
OUT=$(as task_app task_app task <<'SQL'
BEGIN;
SET LOCAL app.organization_id = '018f0000-0000-7000-8000-000000000002';
SELECT count(*) FROM tasks;
COMMIT;
SQL
)
check 'another organization: no row' '[[ $OUT == 0 ]]'
OUT=$(as task_app task_app task <<'SQL'
BEGIN;
SET LOCAL app.organization_id = '018f0000-0000-7000-8000-000000000001';
SELECT title FROM tasks;
COMMIT;
SQL
)
check 'its organization: the row' '[[ $OUT == CAD-482 ]]'
OUT=$(superuser -c "SELECT rolbypassrls OR rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname = 'task_app'")
check 'no attribute that lifts the policies' '[[ $OUT == f ]]'

echo '=== 4. a service stays in its own database'
OUT=$(as task_app task_app organization -c 'SELECT 1') || true
check 'application role refused elsewhere' '[[ $OUT == *"permission denied for database"* ]]'
OUT=$(as task_migrator task_migrator organization -c 'SELECT 1') || true
check 'migrator refused elsewhere' '[[ $OUT == *"permission denied for database"* ]]'
OUT=$(as task_app wrong-password task -c 'SELECT 1') || true
check 'wrong password refused' '[[ $OUT == *"password authentication failed"* ]]'

echo '=== 5. timeouts are set per role'
OUT=$(as task_app task_app task -c 'SHOW statement_timeout' -c 'SHOW lock_timeout' \
  -c 'SHOW idle_in_transaction_session_timeout' | tr '\n' ' ')
check 'application role' '[[ $OUT == "10s 5s 30s " ]]'
OUT=$(as task_migrator task_migrator task -c 'SHOW statement_timeout' -c 'SHOW lock_timeout' \
  -c 'SHOW idle_in_transaction_session_timeout' | tr '\n' ' ')
check 'migrator' '[[ $OUT == "15min 5s 1min " ]]'
OUT=$(as task_app task_app task -c 'SET statement_timeout = 200' -c 'SELECT pg_sleep(2)') || true
check 'a statement past its timeout is cancelled' '[[ $OUT == *"statement timeout"* ]]'

echo '=== 6. a second run changes nothing; a rotated password is applied'
OUT=$(run_init) || OUT="failed: $OUT"
check 'second run succeeds' '[[ $OUT != failed:* ]]'
OUT=$(superuser -d task -c 'SELECT count(*) FROM tasks')
check 'data kept' '[[ $OUT == 1 ]]'
OUT=$(run_init -e TASK_DB_APP_PASSWORD=rotated) || OUT="failed: $OUT"
check 'run with a new password succeeds' '[[ $OUT != failed:* ]]'
OUT=$(as task_app rotated task -c 'SELECT 1')
check 'new password accepted' '[[ $OUT == 1 ]]'
OUT=$(as task_app task_app task -c 'SELECT 1') || true
check 'old password refused' '[[ $OUT == *"password authentication failed"* ]]'
OUT=$(run_init -e TASK_DB_APP_PASSWORD=) || true
check 'a missing password stops the run' '[[ $OUT == *"password of the \"task\" database roles is missing"* ]]'

echo '=== 7. a volume created with the former single role is brought up to date'
superuser >/dev/null <<'SQL'
CREATE ROLE search LOGIN PASSWORD 'search';
ALTER DATABASE search OWNER TO search;
SQL
superuser -d search >/dev/null <<'SQL'
SET ROLE search;
CREATE TABLE documents (id serial PRIMARY KEY, title text);
INSERT INTO documents (title) VALUES ('kept');
SQL
OUT=$(run_init) || OUT="failed: $OUT"
check 'run succeeds' '[[ $OUT != failed:* ]]'
OUT=$(superuser -c "SELECT count(*) FROM pg_roles WHERE rolname = 'search'")
check 'former role dropped' '[[ $OUT == 0 ]]'
OUT=$(superuser -d search -c "SELECT tableowner FROM pg_tables WHERE tablename = 'documents'")
check 'its table now belongs to the migrator' '[[ $OUT == search_migrator ]]'
OUT=$(as search_app search_app search -c "INSERT INTO documents (title) VALUES ('new')" \
  -c 'SELECT count(*) FROM documents')
check 'the application role reads and writes it' '[[ $OUT == 2 ]]'
OUT=$(as search_app search_app search -c 'DROP TABLE documents') || true
check 'and still cannot drop it' '[[ $OUT == *"must be owner of table documents"* ]]'

exit "$FAILED"
