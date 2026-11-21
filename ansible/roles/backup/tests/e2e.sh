#!/usr/bin/env bash
# Exercises PostgreSQL backup and guarded restoration against Docker and a local rclone S3 endpoint.
#
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD/ansible/roles/backup:/backup:ro" docker:28.5.2-cli \
#     sh -c "apk add --no-cache bash >/dev/null && bash /backup/tests/e2e.sh"
#
# CADENWAY_E2E_PREPARED=1 reuses installed dependencies and cached service images.
# Run only inside a disposable container: this fixture writes its own /etc/cadenway configuration.
set -euo pipefail
pull_policy=()
if [[ ${CADENWAY_E2E_PREPARED:-0} == 1 ]]; then
  pull_policy=(--pull never)
else
  apk add --quiet --no-cache bash jq curl age rclone util-linux coreutils >/dev/null
  curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
  chmod +x /usr/local/bin/sops
fi
echo 'e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b  /usr/local/bin/sops' | sha256sum -c -
export SOPS_DISABLE_VERSION_CHECK=1
echo "Using $(/usr/local/bin/sops --version)"
for script in backup restore; do
  cp "/backup/files/cadenway-$script.sh" "/usr/local/bin/cadenway-$script"
  chmod +x "/usr/local/bin/cadenway-$script"
done

TEST_DIR=$(mktemp -d /tmp/cw-backup-e2e.XXXXXXXXXX)
suffix=${TEST_DIR##*.}
readonly TEST_DIR
readonly TEST_ENV="test-${suffix,,}"
readonly PROJECT="cadenway-$TEST_ENV"
readonly SERVER="$PROJECT-postgres" TASK="$PROJECT-task" RELAY="$PROJECT-relay"
readonly BUCKET_DIR="/data/backups/$TEST_ENV"
readonly BACKUP_KEY="$TEST_DIR/backup.key"
readonly PG='postgres:18.6-alpine@sha256:9ba53c7d41ea093baf5c1ba635ba5434c4f979880527d49bb7d9237d3193085b'
mkdir -p /run/lock /etc/cadenway "$BUCKET_DIR"
# Registered with trap below.
# shellcheck disable=SC2329
cleanup() {
  touch "$TEST_DIR/release-restore"
  command docker rm -fv "$SERVER" "$TASK" "$RELAY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d "${pull_policy[@]}" --network none --name "$SERVER" -e POSTGRES_HOST_AUTH_METHOD=trust \
  --label "com.docker.compose.project=$PROJECT" --label com.docker.compose.service=postgres \
  "$PG" >/dev/null

# Use cooperative PID 1 shutdown and a real Docker healthcheck for both workloads.
start_workload() {
  local name=$1 service=$2
  docker run -d "${pull_policy[@]}" --network none --name "$name" \
    --label "com.docker.compose.project=$PROJECT" --label "com.docker.compose.service=$service" \
    --health-cmd 'test ! -e /tmp/force-unhealthy' --health-interval 1s \
    --health-timeout 1s --health-retries 1 \
    busybox:1.37.0 sh -c 'trap "exit 0" TERM INT; while :; do sleep 1 & wait "$!"; done'
}
TEST_TASK=$(start_workload "$TASK" task-service)
TEST_RELAY=$(start_workload "$RELAY" task-service-relay)
export SERVER TEST_DIR TEST_TASK TEST_RELAY

poll() {
  for _ in {1..150}; do
    "$@" && return 0
    sleep 0.2
  done
  return 1
}
# Passed by name to poll and check.
# shellcheck disable=SC2329
healthy() { [[ $(docker inspect --format '{{.State.Health.Status}}' "$1") == healthy ]]; }
poll docker exec "$SERVER" pg_isready -h 127.0.0.1 -U postgres -q
poll healthy "$TASK"
poll healthy "$RELAY"
sql() { docker exec -i "$SERVER" psql -U postgres -v ON_ERROR_STOP=1 -tAq "$@"; }
app() { docker exec -i "$SERVER" psql -U task_app -d task -v ON_ERROR_STOP=1 -tAq "$@" 2>&1; }
database_id() { sql -c "SELECT oid FROM pg_database WHERE datname = 'task'"; }
started_at() { docker inspect --format '{{.State.StartedAt}}' "$1"; }
temporary_archives() { find /var/lib -maxdepth 1 -type d -name 'cadenway-restore*'; }
candidate_databases() { sql -c "SELECT datname FROM pg_database WHERE starts_with(datname, 'cw_restore_candidate_')"; }
# Passed by name to fails.
# shellcheck disable=SC2329
can_read_migration_journal() { app -c 'SELECT count(*) FROM drizzle.__drizzle_migrations' >/dev/null; }

sql <<'SQL'
CREATE ROLE task_migrator LOGIN;
CREATE ROLE task_app LOGIN;
CREATE DATABASE task OWNER task_migrator;
REVOKE ALL ON DATABASE task FROM PUBLIC;
GRANT CONNECT ON DATABASE task TO task_app;
SQL
sql -d task <<'SQL'
SET ROLE task_migrator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO task_app;
CREATE SCHEMA drizzle;
CREATE TABLE drizzle.__drizzle_migrations (id serial PRIMARY KEY, hash text NOT NULL, created_at bigint);
INSERT INTO drizzle.__drizzle_migrations (hash, created_at) VALUES ('initial-fixture-schema', 1);
CREATE TABLE tasks (id text PRIMARY KEY, title text);
INSERT INTO tasks VALUES ('CAD-482', 'Écran SSO');
CREATE TABLE attachment_metadata (id integer PRIMARY KEY, payload text NOT NULL);
INSERT INTO attachment_metadata
  SELECT n, md5('a' || n) || md5('b' || n) || md5('c' || n) || md5('d' || n)
  FROM generate_series(1, 125000) AS n;
SQL
payload_fingerprint() {
  sql -d task -c "SELECT count(*) || ':' || md5(string_agg(payload, '' ORDER BY id)) FROM attachment_metadata"
}
FINGERPRINT=$(payload_fingerprint)

# The S3 endpoint exposes only its own container's loopback and the credentials are disposable.
rclone serve s3 /data --addr 127.0.0.1:9000 --auth-key fixture,fixture-only >/tmp/s3.log 2>&1 &
sleep 2
age-keygen -o /etc/cadenway/age.key 2>/dev/null
age-keygen -o "$BACKUP_KEY" 2>/dev/null
RECIPIENT=$(age-keygen -y "$BACKUP_KEY")
cat >/etc/cadenway/backup.env <<EOF
CADENWAY_ENVIRONMENTS=$TEST_ENV
CADENWAY_BACKUP_DATABASES="task missing"
CADENWAY_BACKUP_RECIPIENT=$RECIPIENT
CADENWAY_BACKUP_RETENTION_DAYS=30
EOF
config_dir="/opt/cadenway/envs/$TEST_ENV/environments/$TEST_ENV"
mkdir -p "$config_dir"
printf '%s\n' BACKUP_S3_ENDPOINT=http://127.0.0.1:9000 BACKUP_S3_REGION=us-east-1 \
  BACKUP_S3_BUCKET=backups BACKUP_S3_ACCESS_KEY_ID=fixture BACKUP_S3_SECRET_ACCESS_KEY=fixture-only \
  ALERT_WEBHOOK_URL= |
  sops encrypt --age "$(age-keygen -y /etc/cadenway/age.key)" --input-type dotenv --output-type dotenv \
    --filename-override secrets.sops.env \
    >"$config_dir/secrets.sops.env"

old_dir="$BUCKET_DIR/20200101T000000Z"
mkdir -p "$old_dir"
echo old >"$old_dir/task.dump.age"
touch -d '2020-01-01' "$old_dir/task.dump.age"

FAILED=0
check() {
  local label=$1
  shift
  if "$@"; then echo "PASS $label"; else echo "FAIL $label"; FAILED=1; fi
}
# Passed by name to check to assert a genuine nonzero exit status.
# shellcheck disable=SC2329
fails() { ! "$@"; }

echo '=== 1. a failed backup keeps older objects'
check 'missing database fails backup' fails cadenway-backup 2>"$TEST_DIR/backup.log"
check 'old backup kept' test -e "$old_dir/task.dump.age"
check 'no partial object for the failed database' test -z "$(find "$BUCKET_DIR" -name missing.dump.age)"

echo '=== 2. a successful backup writes a large encrypted archive and applies retention'
sed -i 's/^CADENWAY_BACKUP_DATABASES=.*/CADENWAY_BACKUP_DATABASES="task"/' /etc/cadenway/backup.env
sleep 1
cadenway-backup 2>"$TEST_DIR/backup.log"
STAMP=$(basename "$(dirname "$(find "$BUCKET_DIR" -name task.dump.age | sort | tail -1)")")
archive="$BUCKET_DIR/$STAMP/task.dump.age"
check 'archive is larger than the failing pipe case' test "$(wc -c <"$archive")" -ge 9273887
check 'dump encrypted' fails grep -q CAD-482 "$archive"
check 'old backup deleted' test ! -e "$old_dir/task.dump.age"

restore() { cadenway-restore "$TEST_ENV" "$1" "$BACKUP_KEY" task; }
reject_restore() {
  local label=$1 stamp=$2
  check "$label" fails restore "$stamp" >"$TEST_DIR/restore-result.log" 2>"$TEST_DIR/restore.log"
  cat "$TEST_DIR/restore-result.log"
}
check_active_database() {
  check 'original database is still active' test "$(database_id)" = "$LIVE_DATABASE"
  check 'live data still readable by application' test "$(app -c 'SELECT title FROM tasks')" = 'live row'
  check 'live schema still present' test "$(sql -d task -c "SELECT to_regclass('added_by_a_later_migration')")" = added_by_a_later_migration
  check 'application is healthy' poll healthy "$TASK"
  check 'companion is healthy' poll healthy "$RELAY"
  check 'candidate database cleaned up' test -z "$(candidate_databases)"
  check 'temporary archives cleaned up' test -z "$(temporary_archives)"
}

sql -d task <<'SQL'
SET ROLE task_migrator;
UPDATE tasks SET title = 'live row';
CREATE TABLE added_by_a_later_migration (id int);
SQL
LIVE_DATABASE=$(database_id)
TASK_STARTED=$(started_at "$TASK")
RELAY_STARTED=$(started_at "$RELAY")

echo '=== 3. missing, damaged and incompatible dumps preserve the live database'
reject_restore 'missing dump rejected' 20991231T000000Z
corrupt_stamp=20991230T000000Z
mkdir -p "$BUCKET_DIR/$corrupt_stamp"
# Keep the header and most of the encrypted data, but cut off the final authenticated block.
head -c -4096 "$archive" >"$BUCKET_DIR/$corrupt_stamp/task.dump.age"
reject_restore 'truncated archive rejected' "$corrupt_stamp"
check_active_database

sql -d task -c "INSERT INTO drizzle.__drizzle_migrations (hash, created_at) VALUES ('newer-live-migration', 2)"
reject_restore 'older journal rejected' "$STAMP"
check 'migration mismatch diagnosed' grep -q 'migration journal differs' "$TEST_DIR/restore.log"
check 'newer migration marker retained' test "$(sql -d task -c 'SELECT max(created_at) FROM drizzle.__drizzle_migrations')" = 2
check_active_database
check 'application never stopped while validating dumps' test "$(started_at "$TASK")" = "$TASK_STARTED"
check 'companion never stopped while validating dumps' test "$(started_at "$RELAY")" = "$RELAY_STARTED"
sql -d task -c 'DELETE FROM drizzle.__drizzle_migrations WHERE created_at = 2'

# Inject deterministic lifecycle failures while forwarding other calls to the real Docker daemon.
targets() {
  local container=$1 arg
  shift
  for arg; do
    [[ $arg == "$container" || $arg == "${container:0:12}" ]] && return 0
  done
  return 1
}
remember_candidate() {
  command docker exec "$SERVER" psql -U postgres -v ON_ERROR_STOP=1 -tAq \
    -c "SELECT oid FROM pg_database WHERE datname = 'task'" >"$TEST_DIR/$TEST_RESTORE_FAULT-candidate"
}
is_candidate_switch() {
  local arg
  targets --set=live=task "$@" || return 1
  for arg; do
    [[ $arg == --set=ready=cw_restore_candidate_* ]] && return 0
  done
  return 1
}
docker() {
  case "${TEST_RESTORE_FAULT:-}:$1" in
    stop:stop)
      if targets "$TEST_TASK" "$@"; then
        if targets "$TEST_RELAY" "$@" &&
           [[ $(command docker inspect --format '{{.State.Running}}' "$TEST_RELAY") == true ]]; then
          command docker stop --time 30 "$TEST_RELAY" >/dev/null || return
        fi
        touch "$TEST_DIR/stop-failure"
        return 75
      fi
      ;;
    start:start)
      if [[ ! -e $TEST_DIR/start-failure ]] && targets "$TEST_RELAY" "$@"; then
        if targets "$TEST_TASK" "$@"; then command docker start "$TEST_TASK" >/dev/null || return; fi
        remember_candidate || return
        touch "$TEST_DIR/start-failure"
        return 75
      fi
      ;;
    health:start)
      if targets "$TEST_TASK" "$@"; then
        command docker "$@" || return
        if [[ ! -e $TEST_DIR/health-failure ]]; then
          command docker exec "$TEST_TASK" touch /tmp/force-unhealthy || return
          remember_candidate || return
          touch "$TEST_DIR/health-failure"
        else
          command docker exec "$TEST_TASK" rm -f /tmp/force-unhealthy || return
        fi
        return 0
      fi
      ;;
    commit:exec)
      if is_candidate_switch "$@"; then
        command docker "$@" || return
        remember_candidate || return
        touch "$TEST_DIR/commit-failure"
        return 75
      fi
      ;;
    hold:exec)
      if targets pg_restore "$@"; then
        touch "$TEST_DIR/restoring-stage"
        poll test -e "$TEST_DIR/release-restore" || return
      fi
      ;;
  esac
  command docker "$@"
}
# Exported to cadenway-restore to shorten only the contender's wait.
# shellcheck disable=SC2329
flock() {
  if [[ ${TEST_SHORT_LOCK:-0} == 1 && $1 == -w ]]; then
    shift 2
    command flock -w 1 "$@"
  else
    command flock "$@"
  fi
}
export -f docker targets remember_candidate is_candidate_switch poll flock

# Passed by name to check for the candidate recorded before rollback.
# shellcheck disable=SC2329
parked_failed_candidate() {
  local fault=$1 oid
  [[ -s $TEST_DIR/$fault-candidate ]] || return 1
  oid=$(<"$TEST_DIR/$fault-candidate")
  [[ $oid != "$LIVE_DATABASE" && $oid =~ ^[0-9]+$ ]] || return 1
  [[ $(sql -c "SELECT starts_with(datname, 'cw_restore_failed_task_') AND NOT datallowconn FROM pg_database WHERE oid = $oid") == t ]]
}

echo '=== 4. failures in stop, commit, start and health preserve or recover the previous workloads'
for fault in stop commit start health; do
  TEST_RESTORE_FAULT=$fault reject_restore "$fault failure reported" "$STAMP"
  check "$fault failure injected" test -e "$TEST_DIR/$fault-failure"
  check_active_database
  if [[ $fault != stop ]]; then
    check "$fault candidate OID remains recoverable with connections disabled" parked_failed_candidate "$fault"
  fi
done

echo '=== 5. an existing client blocks renaming without disconnect or database change'
external_pid() {
  sql -c "SELECT pid FROM pg_stat_activity WHERE datname = 'task' AND application_name = 'cw_restore_external_client'"
}
# Passed by name to poll before attempting the restore.
# shellcheck disable=SC2329
external_connected() { [[ -n $(external_pid) ]]; }
sql -d task -c "SET application_name = 'cw_restore_external_client'; SELECT pg_sleep(120)" >"$TEST_DIR/external.log" 2>&1 &
external_client=$!
check 'external client connected before restore' poll external_connected
external_backend=$(external_pid)
reject_restore 'another client prevents cutover' "$STAMP"
check 'same external PostgreSQL backend still connected' test "$(external_pid)" = "$external_backend"
check_active_database
sql -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE datname = 'task' AND application_name = 'cw_restore_external_client'" >/dev/null
wait "$external_client" || true

echo '=== 6. a competing run cannot remove the active archive'
TEST_RESTORE_FAULT=hold restore "$STAMP" 2>"$TEST_DIR/first-restore.log" &
first_restore=$!
check 'first run reached the staging database' poll test -e "$TEST_DIR/restoring-stage"
active_archives=$(temporary_archives)
check 'first run owns a private temporary directory' test -d "$active_archives"
TEST_SHORT_LOCK=1 reject_restore 'second restore does not acquire the lock' "$STAMP"
check 'second run left first run archive in place' test -s "$active_archives/task.dump.age"
check 'live database still active before cutover' test "$(database_id)" = "$LIVE_DATABASE"
touch "$TEST_DIR/release-restore"
check 'first restore succeeds after contender exits' wait "$first_restore"
if [[ $FAILED != 0 ]]; then cat "$TEST_DIR/first-restore.log" >&2; fi

echo '=== 7. cutover restores the complete backup and keeps the previous database disabled'
check 'backup row restored' test "$(sql -d task -c 'SELECT title FROM tasks')" = 'Écran SSO'
check 'large archive contents match the backup' test "$(payload_fingerprint)" = "$FINGERPRINT"
check 'application reads restored data' test "$(app -c 'SELECT title FROM tasks')" = 'Écran SSO'
check 'table from later migration absent in restored database' test -z "$(sql -d task -c "SELECT to_regclass('added_by_a_later_migration')")"
check 'table still owned by migrator' test "$(sql -d task -c "SELECT tableowner FROM pg_tables WHERE tablename = 'tasks'")" = task_migrator
check 'application cannot change schema' grep -Fq 'must be owner of table tasks' <<<"$(app -c 'DROP TABLE tasks')"
check 'application cannot read migration journal' fails can_read_migration_journal
sql -d task -c 'SET ROLE task_migrator' -c 'CREATE TABLE added_after_the_restore (id int)'
check 'application can read later tables' test -z "$(app -c 'SELECT id FROM added_after_the_restore')"
check 'application started again healthy' healthy "$TASK"
check 'companion started again healthy' healthy "$RELAY"
check 'application was restarted' test "$(started_at "$TASK")" != "$TASK_STARTED"
check 'companion was restarted' test "$(started_at "$RELAY")" != "$RELAY_STARTED"
check 'active database is the staged copy' test "$(database_id)" != "$LIVE_DATABASE"
check 'previous database remains disabled' test "$(sql -c "SELECT datallowconn FROM pg_database WHERE oid = $LIVE_DATABASE")" = f
check 'no staging database remains' test -z "$(candidate_databases)"
check 'no temporary archives remain' test -z "$(temporary_archives)"

echo '=== 8. cold restore creates a database when no live database exists'
docker stop "$TEST_RELAY" "$TEST_TASK" >/dev/null
sql -c 'DROP DATABASE task'
restore "$STAMP"
check 'cold restore makes application data readable' test "$(app -c 'SELECT title FROM tasks')" = 'Écran SSO'
check 'cold restore preserves full archive contents' test "$(payload_fingerprint)" = "$FINGERPRINT"
check 'cold restore leaves no staging database' test -z "$(candidate_databases)"
check 'cold restore leaves no temporary archive' test -z "$(temporary_archives)"

exit "$FAILED"
