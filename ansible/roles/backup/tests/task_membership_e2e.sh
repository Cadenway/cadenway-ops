#!/usr/bin/env bash
# Sourced by the default backup suite after its Storage scenarios.

echo '=== 13. restore Task against the live Organization membership catalog'
docker rm -fv "$SERVER" "$TASK" "$RELAY" >/dev/null
start_membership_postgres

fixture_context=$(mktemp -d "$TEST_DIR/task-memberships.XXXXXXXX")
printf 'FROM %s\nCOPY node /usr/local/bin/node\n' "$PG" >"$fixture_context/Dockerfile"
cat >"$fixture_context/node" <<'SH'
#!/bin/sh
set -eu
[ "$1" = --import ] && [ "$2" = @cadenway/nest-common/register ] || exit 64
case $3 in
  dist/modules/organizations/infrastructure/adapters/membership-export/export-memberships.js)
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c 'SELECT line FROM snapshot ORDER BY position'
    [ "$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAq -c 'SELECT fail_export FROM fixture_control')" = f ]
    ;;
  dist/infrastructure/maintenance/rebuild-memberships.js)
    [ "$4" = --database ] && [ "${DATABASE_URL##*/}" = task ] || exit 64
    case $5 in cw_restore_candidate_task_????????) ;; *) exit 64 ;; esac
    IFS= read -r header && [ "$header" = '{"kind":"header","version":1}' ] || exit 65
    IFS= read -r membership
    IFS= read -r footer && [ "$footer" = '{"kind":"footer","count":1}' ] || exit 65
    if IFS= read -r more; then exit 65; fi
    psql "${DATABASE_URL%/task}/$5" -v ON_ERROR_STOP=1 -q --set=record="$membership" <<'SQL'
INSERT INTO task_membership_fixture VALUES (
  (:'record'::jsonb ->> 'memberId'), (:'record'::jsonb ->> 'role'), (:'record'::jsonb ->> 'version')::int
)
ON CONFLICT (member_id) DO UPDATE SET role = excluded.role, version = excluded.version;
SQL
    ;;
  *) exit 64 ;;
esac
SH
chmod 0755 "$fixture_context/node"
if ! docker build --network none --pull=false --tag "$MEMBERSHIP_FIXTURE" "$fixture_context" >"$TEST_DIR/membership-build.log" 2>&1; then
  cat "$TEST_DIR/membership-build.log" >&2
  exit 1
fi

start_membership_workload "$TASK" task-service "postgres://task_app@$SERVER/task" "$MEMBERSHIP_FIXTURE" >/dev/null
start_workload "$RELAY" task-service-relay >/dev/null
start_membership_workload "$ORGANIZATION" organization-service "postgres://organization_app@$SERVER/organization" "$MEMBERSHIP_FIXTURE" >/dev/null
poll healthy "$TASK"
poll healthy "$RELAY"
poll healthy "$ORGANIZATION"

sql <<'SQL'
CREATE ROLE task_migrator LOGIN;
CREATE ROLE task_app LOGIN;
CREATE ROLE organization_app LOGIN;
CREATE DATABASE task OWNER task_migrator;
CREATE DATABASE organization OWNER organization_app;
SQL
sql -d task <<'SQL'
SET ROLE task_migrator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO task_app;
CREATE TABLE tasks (title text);
INSERT INTO tasks VALUES ('in task backup');
CREATE TABLE task_membership_fixture (member_id text PRIMARY KEY, role text, version int);
INSERT INTO task_membership_fixture VALUES ('018b6300-0000-7000-8000-000000000002', 'owner', 1);
SQL
sql -d organization <<'SQL'
SET ROLE organization_app;
CREATE TABLE snapshot (position int PRIMARY KEY, line text NOT NULL);
INSERT INTO snapshot VALUES
  (1, '{"kind":"header","version":1}'),
  (2, '{"kind":"membership","organizationId":"018b6300-0000-7000-8000-000000000001","memberId":"018b6300-0000-7000-8000-000000000002","userId":"018b6300-0000-7000-8000-000000000003","role":"member","version":2,"removedAt":null,"updatedAt":"2026-11-22T12:00:00.000Z"}'),
  (3, '{"kind":"footer","count":1}');
CREATE TABLE fixture_control (fail_export boolean NOT NULL);
INSERT INTO fixture_control VALUES (false);
SQL

sed -i 's/^CADENWAY_BACKUP_DATABASES=.*/CADENWAY_BACKUP_DATABASES="task"/' /etc/cadenway/backup.env
sleep 1
cadenway-backup 2>"$TEST_DIR/membership-backup.log"
MEMBERSHIP_STAMP=$(backup_stamp task)
sql -d task -c "UPDATE tasks SET title = 'live before rebuild'"
membership_restore() {
  cadenway-restore --rebuild-task-memberships "$TEST_ENV" "$MEMBERSHIP_STAMP" "$BACKUP_KEY" task
}
membership_importers() {
  docker ps -a --no-trunc -q --filter "label=com.cadenway.restore.environment=$TEST_ENV"
}
check_membership_rollback() {
  local importers candidates
  importers=$(membership_importers)
  candidates=$(candidate_databases)
  check 'the original Task database still serves requests' test "$(database_id):$(app -c 'SELECT title FROM tasks')" = "$original_task:live before rebuild"
  check 'both original Task workloads are healthy' poll healthy "$TASK"
  check 'original Task relay restarted successfully' poll healthy "$RELAY"
  check 'no membership importer or candidate remains' test -z "$importers$candidates"
  check 'restore did not leave an unresolved journal' test ! -e "$RESTORE_JOURNAL"
}

original_task=$(database_id)
check 'membership mode rejects a multi-database restore' fails cadenway-restore --rebuild-task-memberships \
  "$TEST_ENV" "$MEMBERSHIP_STAMP" "$BACKUP_KEY" organization task

# The exporter can report failure after emitting a complete stream. Even a successful importer
# cannot promote that candidate because both exits are checked.
sql -d organization -c 'UPDATE fixture_control SET fail_export = true'
check 'producer exit after a complete stream prevents promotion' fails membership_restore
check_membership_rollback
sql -d organization -c 'UPDATE fixture_control SET fail_export = false'

sql -d organization -c "UPDATE snapshot SET line = '{\"kind\":\"footer\",\"count\":2}' WHERE position = 3"
check 'importer rejection prevents promotion' fails membership_restore
check_membership_rollback
sql -d organization -c "UPDATE snapshot SET line = '{\"kind\":\"footer\",\"count\":1}' WHERE position = 3"

check 'interruption with the candidate open leaves durable recovery state' fails env \
  TEST_RESTORE_FAULT=interrupt-memberships cadenway-restore --rebuild-task-memberships \
  "$TEST_ENV" "$MEMBERSHIP_STAMP" "$BACKUP_KEY" task 2>"$TEST_DIR/membership-interrupt.log"
check 'journal survives the interrupted rebuild' test -f "$RESTORE_JOURNAL"
check 'interrupted rebuild left the candidate open' test \
  "$(sql -c "SELECT datallowconn FROM pg_database WHERE datname LIKE 'cw_restore_candidate_task_%'")" = t
interrupted_suffix=$(jq -er '.suffix | select(test("^[A-Za-z0-9]{8}$"))' "$RESTORE_JOURNAL")
MEMBERSHIP_ORPHAN="cadenway-$TEST_ENV-restore-memberships-$interrupted_suffix"
docker run -d --pull never --network "$MEMBERSHIP_NETWORK" --name "$MEMBERSHIP_ORPHAN" \
  --label "com.cadenway.restore.environment=$TEST_ENV" --label "com.cadenway.restore.candidate=$interrupted_suffix" \
  --entrypoint sleep "$MEMBERSHIP_FIXTURE" 300 >/dev/null
cadenway-restore --recover "$TEST_ENV"
check_membership_rollback

organization_start=$(started_at "$ORGANIZATION")
membership_restore
check 'restored task contents replace live writes after the dump' test "$(app -c 'SELECT title FROM tasks')" = 'in task backup'
check 'rebuild uses the current Organization role and version' test \
  "$(app -c "SELECT role || ':' || version FROM task_membership_fixture")" = 'member:2'
check 'successful restore promoted a different Task database' test "$(database_id)" != "$original_task"
check 'Organization kept running throughout the restore' test "$(started_at "$ORGANIZATION")" = "$organization_start"
check 'Task resumes with the rebuilt projection' poll healthy "$TASK"
check 'Task relay resumes with the rebuilt projection' poll healthy "$RELAY"
check 'no membership importer or candidate remains' test -z "$(membership_importers)$(candidate_databases)"
check 'no journal remains after successful rebuild' test ! -e "$RESTORE_JOURNAL"
