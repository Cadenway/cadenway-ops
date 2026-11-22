#!/usr/bin/env bash
# Exercises PostgreSQL and versioned Storage recovery against disposable S3 endpoints.
#
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD/ansible/roles/backup:/backup:ro" docker:28.5.2-cli \
#     sh -c "apk add --no-cache bash >/dev/null && bash /backup/tests/e2e.sh"
#
# CADENWAY_E2E_PREPARED=1 reuses installed dependencies and cached service images.
# Set CADENWAY_E2E_STORAGE_IMAGE to a local image ID in a prepared, network-isolated runner
# to select the real Storage API scenario. See docs/deployment.md for the invocation.
# Run only inside a disposable container: this fixture writes its own /etc/cadenway configuration.
set -euo pipefail

verify_sops() {
  echo 'e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b  /usr/local/bin/sops' | sha256sum -c -
}

install_runner_dependencies() {
  apk add --quiet --no-cache bash jq curl age rclone util-linux coreutils openssh-keygen python3 py3-boto3 >/dev/null
  curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
  chmod +x /usr/local/bin/sops
  verify_sops
}

if [[ $# == 1 && $1 == --prepare-runner ]]; then
  install_runner_dependencies
  exit 0
fi
if [[ $# != 0 ]]; then
  echo 'Usage: bash /backup/tests/e2e.sh [--prepare-runner]' >&2
  exit 2
fi

if [[ -v CADENWAY_E2E_STORAGE_IMAGE ]]; then
  if [[ ! $CADENWAY_E2E_STORAGE_IMAGE =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo 'CADENWAY_E2E_STORAGE_IMAGE must be a complete local Docker image ID (sha256:…).' >&2
    exit 2
  fi
  if ! docker image inspect "$CADENWAY_E2E_STORAGE_IMAGE" >/dev/null 2>&1; then
    echo 'CADENWAY_E2E_STORAGE_IMAGE is not available in the local Docker engine.' >&2
    exit 2
  fi
  if [[ ${CADENWAY_E2E_PREPARED:-0} != 1 || $(docker inspect --format '{{.HostConfig.NetworkMode}}' "$HOSTNAME") != none ]]; then
    echo 'The real Storage scenario requires a prepared runner with --network none.' >&2
    exit 2
  fi
fi

pull_policy=()
if [[ ${CADENWAY_E2E_PREPARED:-0} == 1 ]]; then
  pull_policy=(--pull never)
  verify_sops
else
  install_runner_dependencies
fi
export SOPS_DISABLE_VERSION_CHECK=1
echo "Using $(/usr/local/bin/sops --version)"
python3 -B /backup/tests/test_restore_objects.py
for script in backup restore; do
  cp "/backup/files/cadenway-$script.sh" "/usr/local/bin/cadenway-$script"
  chmod +x "/usr/local/bin/cadenway-$script"
done
install -D -m 0644 /backup/files/cadenway-restore-objects.py /usr/local/lib/cadenway/cadenway-restore-objects.py

TEST_DIR=$(mktemp -d /tmp/cw-backup-e2e.XXXXXXXXXX)
suffix=${TEST_DIR##*.}
readonly TEST_DIR
readonly TEST_ENV="test-${suffix,,}"
readonly PROJECT="cadenway-$TEST_ENV"
readonly SERVER="$PROJECT-postgres" TASK="$PROJECT-task" RELAY="$PROJECT-relay"
readonly STORAGE="$PROJECT-storage" FILES_S3="$PROJECT-files-s3" BROKER="$PROJECT-nats"
readonly BUCKET_DIR="/data/backups/$TEST_ENV"
readonly BACKUP_KEY="$TEST_DIR/backup.key"
readonly PG='postgres:18.6-alpine@sha256:9ba53c7d41ea093baf5c1ba635ba5434c4f979880527d49bb7d9237d3193085b'
# SeaweedFS 4.54 handles conditional copies after presigned POST and restores behind delete markers.
readonly SEAWEEDFS='chrislusf/seaweedfs@sha256:4b42c212543a0acd4c0e675215ecdcaf62a186ef98def76c7e12701871222d15'
export STORAGE_S3_ENDPOINT=http://127.0.0.1:8333 STORAGE_S3_REGION=us-east-1 STORAGE_S3_BUCKET=attachments
export STORAGE_RESTORE_S3_ACCESS_KEY_ID=storage-fixture STORAGE_RESTORE_S3_SECRET_ACCESS_KEY=storage-fixture-only
mkdir -p /run/lock /etc/cadenway "$BUCKET_DIR"
# Registered with trap below.
# shellcheck disable=SC2329
cleanup() {
  local status=$? name remaining
  local -a containers=("$FILES_S3" "$STORAGE" "$SERVER" "$TASK" "$RELAY" "$BROKER") filters=()
  trap - EXIT
  trap '' INT TERM
  touch "$TEST_DIR/release-restore" || true
  command docker rm -fv "${containers[@]}" >/dev/null 2>&1 || true
  for name in "${containers[@]}"; do filters+=(--filter "name=^/$name$"); done
  if ! remaining=$(command docker ps -a "${filters[@]}" --format '{{.Names}}'); then
    echo 'Could not verify backup fixture container cleanup.' >&2
    if ((status == 0)); then status=1; fi
  elif [[ -n $remaining ]]; then
    printf 'Backup fixture containers still present after cleanup:\n%s\n' "$remaining" >&2
    if ((status == 0)); then status=1; fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
sql() { docker exec -i "$SERVER" psql -U postgres -v ON_ERROR_STOP=1 -tAq "$@"; }
started_at() { docker inspect --format '{{.State.StartedAt}}' "$1"; }
temporary_archives() { find /var/lib -maxdepth 1 -type d -name 'cadenway-restore*'; }
candidate_databases() { sql -c "SELECT datname FROM pg_database WHERE starts_with(datname, 'cw_restore_candidate_')"; }
storage_stamp() {
  backup_stamp storage
}
backup_stamp() {
  basename "$(dirname "$(find "$BUCKET_DIR" -type f -name "$1.manifest.json" | sort | tail -1)")"
}
backup_archive() {
  local archive
  archive=$(jq -er '.manifest | fromjson | .object' "$BUCKET_DIR/$1/$2.manifest.json") || return 1
  printf '/data/backups/%s\n' "$archive"
}
storage_db_id() { sql -c "SELECT oid FROM pg_database WHERE datname = 'storage'"; }
storage_restore() { cadenway-restore "$TEST_ENV" "$1" "$BACKUP_KEY" storage; }
storage_fixture() { python3 -B /backup/tests/storage_fixture.py "$@"; }

# Keep the application bucket separate from the rclone bucket that stores encrypted database dumps.
start_files_s3() {
  docker run -d "${pull_policy[@]}" --network "container:$HOSTNAME" --name "$FILES_S3" \
    -e "AWS_ACCESS_KEY_ID=$STORAGE_RESTORE_S3_ACCESS_KEY_ID" \
    -e "AWS_SECRET_ACCESS_KEY=$STORAGE_RESTORE_S3_SECRET_ACCESS_KEY" \
    "$SEAWEEDFS" server -s3 -s3.port=8333 -ip.bind=127.0.0.1 -ip=127.0.0.1 >/dev/null
  if ! poll storage_fixture ready 2>"$TEST_DIR/files-s3.log"; then
    cat "$TEST_DIR/files-s3.log" >&2
    return 1
  fi
}

start_postgres() {
  docker run -d "${pull_policy[@]}" --network "$1" --name "$SERVER" -e POSTGRES_HOST_AUTH_METHOD=trust \
    --label "com.docker.compose.project=$PROJECT" --label com.docker.compose.service=postgres \
    "$PG" >/dev/null
  poll docker exec "$SERVER" pg_isready -h 127.0.0.1 -U postgres -q
}

prepare_backups() {
  local databases=$1 recipient config_dir
  # The S3 endpoint exposes only its own container's loopback and the credentials are disposable.
  rclone serve s3 /data --addr 127.0.0.1:9000 --auth-key fixture,fixture-only >"$TEST_DIR/backup-s3.log" 2>&1 &
  poll curl --silent --max-time 2 -o /dev/null http://127.0.0.1:9000/
  age-keygen -o /etc/cadenway/age.key 2>/dev/null
  age-keygen -o "$BACKUP_KEY" 2>/dev/null
  ssh-keygen -q -t ed25519 -N '' -f /etc/cadenway/backup-signing.key
  printf 'cadenway-backup %s\n' "$(cut -d ' ' -f 1,2 /etc/cadenway/backup-signing.key.pub)" \
    >/etc/cadenway/backup-allowed-signers
  recipient=$(age-keygen -y "$BACKUP_KEY")
  cat >/etc/cadenway/backup.env <<EOF
CADENWAY_ENVIRONMENTS=$TEST_ENV
CADENWAY_BACKUP_DATABASES="$databases"
CADENWAY_BACKUP_RECIPIENT=$recipient
EOF
  config_dir="/opt/cadenway/envs/$TEST_ENV/environments/$TEST_ENV"
  mkdir -p "$config_dir"
  printf '%s\n' BACKUP_S3_ENDPOINT=http://127.0.0.1:9000 BACKUP_S3_REGION=us-east-1 \
    BACKUP_S3_BUCKET=backups BACKUP_S3_ACCESS_KEY_ID=fixture BACKUP_S3_SECRET_ACCESS_KEY=fixture-only \
    "STORAGE_S3_ENDPOINT=$STORAGE_S3_ENDPOINT" "STORAGE_S3_REGION=$STORAGE_S3_REGION" \
    "STORAGE_S3_BUCKET=$STORAGE_S3_BUCKET" STORAGE_S3_FORCE_PATH_STYLE=true \
    "STORAGE_RESTORE_S3_ACCESS_KEY_ID=$STORAGE_RESTORE_S3_ACCESS_KEY_ID" \
    "STORAGE_RESTORE_S3_SECRET_ACCESS_KEY=$STORAGE_RESTORE_S3_SECRET_ACCESS_KEY" \
    ALERT_WEBHOOK_URL= |
    sops encrypt --age "$(age-keygen -y /etc/cadenway/age.key)" --input-type dotenv --output-type dotenv \
      --filename-override secrets.sops.env \
      >"$config_dir/secrets.sops.env"
}

if [[ -v CADENWAY_E2E_STORAGE_IMAGE ]]; then
  # shellcheck source=ansible/roles/backup/tests/storage_e2e.sh
  source /backup/tests/storage_e2e.sh
  exit 0
fi

start_postgres none

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

poll healthy "$TASK"
poll healthy "$RELAY"
app() { docker exec -i "$SERVER" psql -U task_app -d task -v ON_ERROR_STOP=1 -tAq "$@" 2>&1; }
database_id() { sql -c "SELECT oid FROM pg_database WHERE datname = 'task'"; }
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

prepare_backups 'task missing'

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
check 'no manifest or partial object for the failed database' test -z "$(find "$BUCKET_DIR" -name 'missing*')"

echo '=== 2. a successful backup publishes a signed manifest and leaves independent retention to Object Storage'
sed -i 's/^CADENWAY_BACKUP_DATABASES=.*/CADENWAY_BACKUP_DATABASES="task"/' /etc/cadenway/backup.env
sleep 1
cadenway-backup 2>"$TEST_DIR/backup.log"
STAMP=$(backup_stamp task)
manifest="$BUCKET_DIR/$STAMP/task.manifest.json"
archive=$(backup_archive "$STAMP" task)
check 'archive is larger than the failing pipe case' test "$(wc -c <"$archive")" -ge 9273887
check 'dump encrypted' fails grep -q CAD-482 "$archive"
check 'old backup remains for independent bucket retention' test -e "$old_dir/task.dump.age"

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

echo '=== 3. untrusted, damaged and incompatible dumps preserve the live database'
reject_restore 'missing dump rejected' 20991231T000000Z
check 'missing manifest diagnosed' grep -Fq 'no trusted backup manifest' "$TEST_DIR/restore.log"
reject_restore 'legacy unsigned archive rejected' 20200101T000000Z
check 'unsigned archive rejected before restore' grep -Fq 'no trusted backup manifest' "$TEST_DIR/restore.log"

cp "$manifest" "$TEST_DIR/original-envelope"
jq -c '.manifest | fromjson | .stamp = "20991230T000000Z"' "$manifest" >"$TEST_DIR/wrong-scope"
ssh-keygen -q -Y sign -f /etc/cadenway/backup-signing.key -n cadenway-backup-manifest-v1 "$TEST_DIR/wrong-scope"
jq -cn --rawfile manifest "$TEST_DIR/wrong-scope" --rawfile signature "$TEST_DIR/wrong-scope.sig" \
  '{$manifest, $signature}' >"$manifest"
reject_restore 'valid manifest for a different timestamp rejected' "$STAMP"
check 'wrong manifest scope diagnosed' grep -Fq 'signed backup manifest has invalid scope or metadata' "$TEST_DIR/restore.log"
cp "$TEST_DIR/original-envelope" "$manifest"

jq -rj .manifest "$manifest" >"$TEST_DIR/untrusted-manifest"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/untrusted-signer"
ssh-keygen -q -Y sign -f "$TEST_DIR/untrusted-signer" -n cadenway-backup-manifest-v1 "$TEST_DIR/untrusted-manifest"
jq --rawfile signature "$TEST_DIR/untrusted-manifest.sig" '.signature = $signature' "$TEST_DIR/original-envelope" >"$manifest"
reject_restore 'manifest from an untrusted signer rejected' "$STAMP"
check 'untrusted signature diagnosed' grep -Fq 'no trusted backup manifest' "$TEST_DIR/restore.log"
cp "$TEST_DIR/original-envelope" "$manifest"

cp "$archive" "$TEST_DIR/original-archive"
head -c -4096 "$TEST_DIR/original-archive" >"$archive"
reject_restore 'truncated archive rejected' "$STAMP"
check 'truncated archive rejected before restore' grep -Fq 'encrypted archive does not match the signed manifest' "$TEST_DIR/restore.log"
cp "$TEST_DIR/original-archive" "$archive"
printf '\000' | dd of="$archive" bs=1 seek=8 count=1 conv=notrunc status=none
reject_restore 'same-size modified archive rejected' "$STAMP"
check 'modified archive rejected before restore' grep -Fq 'encrypted archive does not match the signed manifest' "$TEST_DIR/restore.log"
cp "$TEST_DIR/original-archive" "$archive"
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
    storage-start:start)
      if [[ ! -e $TEST_DIR/storage-start-failure ]] && targets "$TEST_STORAGE" "$@"; then
        touch "$TEST_DIR/storage-start-failure"
        return 75
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

start_files_s3
TEST_STORAGE=$(start_workload "$STORAGE" storage-service)
export TEST_STORAGE
poll healthy "$STORAGE"

readonly FIXTURE_ORGANIZATION=018b6300-0000-7000-8000-000000000000
export FIXTURE_ATTACHMENT_KEY="org/$FIXTURE_ORGANIZATION/018b6300-0000-7000-8000-000000000001"
export FIXTURE_INTAKE_KEY="org/$FIXTURE_ORGANIZATION/018b6300-0000-7000-8000-000000000002"
export FIXTURE_PROFILE_ID=018b6300-0000-7000-8000-000000000003
export FIXTURE_POST_DUMP_KEY="org/$FIXTURE_ORGANIZATION/018b6300-0000-7000-8000-000000000004"
readonly MISSING_KEY="org/$FIXTURE_ORGANIZATION/018b6300-0000-7000-8000-000000000005"
readonly PURGED_KEY="org/$FIXTURE_ORGANIZATION/018b6300-0000-7000-8000-000000000006"

storage_fixture seed

sql <<'SQL'
CREATE ROLE storage_migrator LOGIN;
CREATE ROLE storage_app LOGIN;
CREATE DATABASE storage OWNER storage_migrator;
REVOKE ALL ON DATABASE storage FROM PUBLIC;
GRANT CONNECT ON DATABASE storage TO storage_app;
SQL
sql -d storage --set=org="$FIXTURE_ORGANIZATION" --set=attachment="$FIXTURE_ATTACHMENT_KEY" \
  --set=intake="$FIXTURE_INTAKE_KEY" --set=profile="$FIXTURE_PROFILE_ID" --set=purged="$PURGED_KEY" <<'SQL'
SET ROLE storage_migrator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO storage_app;
CREATE SCHEMA drizzle;
CREATE TABLE drizzle.__drizzle_migrations (id serial PRIMARY KEY, hash text NOT NULL, created_at bigint);
INSERT INTO drizzle.__drizzle_migrations (hash, created_at) VALUES ('storage-fixture-schema', 1);
CREATE TABLE attachments (
  id text PRIMARY KEY, status text NOT NULL, scan_status text NOT NULL,
  elected_object_key text, size_bytes bigint NOT NULL, organization_id uuid NOT NULL, task_key text NOT NULL
);
CREATE TABLE attachment_task_tombstones (
  organization_id uuid NOT NULL, task_key text NOT NULL, purged_at timestamptz,
  PRIMARY KEY (organization_id, task_key)
);
CREATE TABLE intake_attachments (
  id text PRIMARY KEY, status text NOT NULL, candidate_key text, size_bytes bigint NOT NULL
);
CREATE TABLE profile_media_owners (
  owner_kind text NOT NULL, owner_id uuid NOT NULL, deleted boolean NOT NULL,
  PRIMARY KEY (owner_kind, owner_id)
);
CREATE TABLE profile_media_uploads (
  upload_id text PRIMARY KEY, status text NOT NULL, candidate_id uuid, derivative_size_bytes integer,
  owner_kind text NOT NULL, owner_id uuid NOT NULL,
  FOREIGN KEY (owner_kind, owner_id) REFERENCES profile_media_owners
);
INSERT INTO attachments VALUES
  ('first', 'ready', 'verified', :'attachment', octet_length('original attachment'), :'org', 'CAD-1'),
  ('staged', 'pending', 'pending', NULL, 15, :'org', 'CAD-2'),
  ('purged', 'ready', 'verified', :'purged', 15, :'org', 'CAD-3');
INSERT INTO attachment_task_tombstones VALUES (:'org', 'CAD-3', now());
INSERT INTO attachment_task_tombstones VALUES (:'org', 'CAD-1', NULL);
INSERT INTO intake_attachments VALUES ('intake', 'verified', :'intake', octet_length('original intake'));
INSERT INTO profile_media_owners VALUES
  ('avatar', '018b6300-0000-7000-8000-000000000007', false),
  ('avatar', '018b6300-0000-7000-8000-000000000008', true);
INSERT INTO profile_media_uploads VALUES
  ('avatar', 'attached', :'profile', octet_length('original avatar'), 'avatar', '018b6300-0000-7000-8000-000000000007'),
  ('deleted-owner', 'prepared', '018b6300-0000-7000-8000-000000000009', 15, 'avatar', '018b6300-0000-7000-8000-000000000008');
SQL

storage_app() { docker exec "$SERVER" psql -U storage_app -d storage -v ON_ERROR_STOP=1 -tAq -c "$1"; }
check_storage_ready() {
  check 'Storage service healthy' poll healthy "$STORAGE"
  check 'Storage candidate cleaned up' test -z "$(candidate_databases)"
  check 'Storage temporary archives cleaned up' test -z "$(temporary_archives)"
}

echo '=== 9. a Storage dump restores bytes hidden by S3 delete markers after backup'
sed -i 's/^CADENWAY_BACKUP_DATABASES=.*/CADENWAY_BACKUP_DATABASES="storage"/' /etc/cadenway/backup.env
cadenway-backup 2>"$TEST_DIR/storage-backup.log"
STORAGE_STAMP=$(storage_stamp)
storage_fixture delete-after-dump >"$TEST_DIR/deleted-versions.json"
add_post_dump_row() {
  sql -d storage --set=object="$FIXTURE_POST_DUMP_KEY" --set=org="$FIXTURE_ORGANIZATION" <<'SQL'
INSERT INTO attachments
VALUES ('after-dump', 'ready', 'verified', :'object', octet_length('uploaded after the dump'), :'org', 'CAD-4');
SQL
}
add_post_dump_row
sql -d storage -c "DELETE FROM attachments WHERE id = 'first'"
STORAGE_BEFORE_RESTORE=$(storage_db_id)
storage_restore "$STORAGE_STAMP"
check 'recovered attachment points to the elected key' test \
  "$(storage_app "SELECT elected_object_key FROM attachments WHERE id = 'first'")" = "$FIXTURE_ATTACHMENT_KEY"
check 'verified intake reservation points to its candidate' test \
  "$(storage_app "SELECT candidate_key FROM intake_attachments WHERE id = 'intake'")" = "$FIXTURE_INTAKE_KEY"
check 'attached profile media points to its derivative' test \
  "$(storage_app "SELECT candidate_id FROM profile_media_uploads WHERE upload_id = 'avatar'")" = "$FIXTURE_PROFILE_ID"
check 'a purged task row does not require its former attachment' test \
  "$(storage_app "SELECT elected_object_key FROM attachments WHERE id = 'purged'")" = "$PURGED_KEY"
check 'a deleted profile owner does not require its former derivative' test \
  "$(storage_app "SELECT status FROM profile_media_uploads WHERE upload_id = 'deleted-owner'")" = prepared
check 'post-dump row is absent from recovered database' test -z "$(storage_app "SELECT id FROM attachments WHERE id = 'after-dump'")"
check 'restored and post-dump bytes are downloadable and original versions remain' \
  storage_fixture verify-restored <"$TEST_DIR/deleted-versions.json"
check 'Storage switched to a restored database' test "$(storage_db_id)" != "$STORAGE_BEFORE_RESTORE"
check_storage_ready

echo '=== 10. repeating the restore preserves the S3 version history'
history=$(storage_fixture history)
storage_restore "$STORAGE_STAMP"
check 'retry does not create or remove object versions' test "$(storage_fixture history)" = "$history"
check_storage_ready

echo '=== 11. rollback keeps the live Storage database and objects active'
add_post_dump_row
live_storage=$(storage_db_id)
check 'Storage restart failure is reported' fails env TEST_RESTORE_FAULT=storage-start \
  cadenway-restore "$TEST_ENV" "$STORAGE_STAMP" "$BACKUP_KEY" storage 2>"$TEST_DIR/storage-restore.log"
check 'Storage restart failure injected' test -e "$TEST_DIR/storage-start-failure"
check 'post-rollback Storage database has its original OID' test "$(storage_db_id)" = "$live_storage"
check 'post-rollback Storage database still contains the new attachment' test \
  "$(storage_app "SELECT elected_object_key FROM attachments WHERE id = 'after-dump'")" = "$FIXTURE_POST_DUMP_KEY"
check 'rollback does not create or remove object versions' test "$(storage_fixture history)" = "$history"
check 'all live objects remain downloadable after rollback' \
  storage_fixture verify-restored <"$TEST_DIR/deleted-versions.json"
check_storage_ready

echo '=== 12. missing or conflicting S3 versions prevent cutover'
sql -d storage --set=object="$MISSING_KEY" --set=org="$FIXTURE_ORGANIZATION" <<'SQL'
INSERT INTO attachments VALUES ('never-uploaded', 'ready', 'verified', :'object', 15, :'org', 'CAD-5');
SQL
# Backup names have second granularity. Keep the original fixture available for the conflict case.
sleep 1
cadenway-backup 2>"$TEST_DIR/storage-backup.log"
MISSING_STAMP=$(storage_stamp)
check 'missing-object snapshot differs from the valid snapshot' test "$MISSING_STAMP" != "$STORAGE_STAMP"
sql -d storage -c "DELETE FROM attachments WHERE id = 'never-uploaded'"
storage_started=$(started_at "$STORAGE")
check 'snapshot with no retained version is rejected' fails storage_restore "$MISSING_STAMP" 2>"$TEST_DIR/storage-restore.log"
check 'missing object diagnosed during preflight' grep -Fq 'Storage object preflight failed' "$TEST_DIR/storage-restore.log"
check 'missing version does not modify the application bucket' test "$(storage_fixture history)" = "$history"
check 'missing version never switches or stops Storage' test "$(storage_db_id):$(started_at "$STORAGE")" = "$live_storage:$storage_started"
check_storage_ready

storage_fixture conflict
history=$(storage_fixture history)
check 'snapshot with conflicting object bytes is rejected' fails storage_restore "$STORAGE_STAMP" 2>"$TEST_DIR/storage-restore.log"
check 'conflicting object diagnosed during preflight' grep -Fq 'Storage object preflight failed' "$TEST_DIR/storage-restore.log"
check 'conflict leaves the current object and all version IDs unchanged' test "$(storage_fixture history)" = "$history"
check 'conflicting version never switches or stops Storage' test "$(storage_db_id):$(started_at "$STORAGE")" = "$live_storage:$storage_started"
check_storage_ready

exit "$FAILED"
