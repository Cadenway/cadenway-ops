#!/usr/bin/env bash
# Run the exact Organization export and Task rebuild binaries through a real restore.

echo '=== Membership recovery with the local Organization and Task images'
start_membership_postgres
prepare_backups task
sql <<'SQL'
CREATE ROLE organization_migrator LOGIN;
CREATE ROLE organization_app LOGIN;
CREATE ROLE task_migrator LOGIN;
CREATE ROLE task_app LOGIN;
CREATE DATABASE organization OWNER organization_migrator;
CREATE DATABASE task OWNER task_migrator;
SQL

apply_service_migrations() {
  local service=$1 image=$2
  sql -d "$service" --set=app="${service}_app" --set=migrator="${service}_migrator" <<'SQL'
GRANT CONNECT ON DATABASE :"DBNAME" TO :"app";
GRANT USAGE ON SCHEMA public TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" IN SCHEMA public
   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" IN SCHEMA public
   GRANT USAGE, SELECT ON SEQUENCES TO :"app";
SQL
  docker run --rm --pull never --network "$MEMBERSHIP_NETWORK" \
    --env "MIGRATION_DATABASE_URL=postgres://${service}_migrator@$SERVER/$service" \
    --entrypoint node "$image" dist/migrate.js
}
apply_service_migrations organization "$CADENWAY_E2E_ORGANIZATION_IMAGE"
apply_service_migrations task "$CADENWAY_E2E_TASK_IMAGE"

start_membership_workload "$ORGANIZATION" organization-service "postgres://organization_app@$SERVER/organization" \
  "$CADENWAY_E2E_ORGANIZATION_IMAGE" >/dev/null
start_membership_workload "$TASK" task-service "postgres://task_app@$SERVER/task" "$CADENWAY_E2E_TASK_IMAGE" >/dev/null
start_membership_workload "$RELAY" task-service-relay "postgres://task_app@$SERVER/task" "$CADENWAY_E2E_TASK_IMAGE" >/dev/null
poll healthy "$TASK"
poll healthy "$RELAY"
poll healthy "$ORGANIZATION"

sql -d task <<'SQL'
SET ROLE task_migrator;
SET app.system_access = 'on';
CREATE TABLE restore_fixture_marker (value text NOT NULL);
INSERT INTO restore_fixture_marker VALUES ('in task backup');
INSERT INTO organization_members (organization_id, id, user_id, role, version, created_at, updated_at) VALUES
  ('018b6300-0000-7000-8000-000000000001', '018b6300-0000-7000-8000-000000000002',
   '018b6300-0000-7000-8000-000000000003', 'admin', 1, '2026-11-01T12:00Z', '2026-11-01T12:00Z'),
  ('018b6300-0000-7000-8000-000000000001', '018b6300-0000-7000-8000-000000000004',
   '018b6300-0000-7000-8000-000000000005', 'guest', 1, '2026-11-01T12:00Z', '2026-11-01T12:00Z');
SQL

cadenway-backup 2>"$TEST_DIR/real-membership-backup.log"
membership_stamp=$(backup_stamp task)
sql -d task -c "UPDATE restore_fixture_marker SET value = 'after dump'"
sql -d organization <<'SQL'
SET ROLE organization_migrator;
SET app.system_access = 'on';
INSERT INTO organizations (id, name, name_key, slug, default_language, team_size, primary_use, owner_user_id)
VALUES ('018b6300-0000-7000-8000-000000000001', 'Restore fixture', 'restore fixture', 'restore-fixture', 'en',
   '1-5', 'other', '018b6300-0000-7000-8000-000000000007');
INSERT INTO members (organization_id, id, user_id, role, version, joined_at, created_at, updated_at, removed_at) VALUES
  ('018b6300-0000-7000-8000-000000000001', '018b6300-0000-7000-8000-000000000002',
   '018b6300-0000-7000-8000-000000000003', 'member', 2, '2026-11-01T12:00Z', '2026-11-01T12:00Z', '2026-11-22T12:00Z', NULL),
  ('018b6300-0000-7000-8000-000000000001', '018b6300-0000-7000-8000-000000000004',
   '018b6300-0000-7000-8000-000000000005', 'guest', 3, '2026-11-01T12:00Z', '2026-11-01T12:00Z', '2026-11-22T12:00Z', '2026-11-22T12:00Z'),
  ('018b6300-0000-7000-8000-000000000001', '018b6300-0000-7000-8000-000000000006',
   '018b6300-0000-7000-8000-000000000007', 'owner', 1, '2026-11-01T12:00Z', '2026-11-01T12:00Z', '2026-11-01T12:00Z', NULL);
SQL

organization_start=$(started_at "$ORGANIZATION")
cadenway-restore --rebuild-task-memberships "$TEST_ENV" "$membership_stamp" "$BACKUP_KEY" task
authority=$(sql -d task -c "SELECT string_agg(
    format('%s:%s:%s', role, version, CASE WHEN removed_at IS NULL THEN 'active' ELSE 'removed' END), ',' ORDER BY id)
  FROM organization_members")
[[ $authority == 'member:2:active,guest:3:removed,owner:1:active' ]]
[[ $(sql -d task -c 'SELECT value FROM restore_fixture_marker') == 'in task backup' ]]
[[ $(started_at "$ORGANIZATION") == "$organization_start" ]]
poll healthy "$TASK"
poll healthy "$RELAY"
[[ ! -e $RESTORE_JOURNAL && -z $(candidate_databases) ]]
echo 'PASS real Organization export and Task import restore current roles and tombstones before promotion'
