#!/usr/bin/env bash
# End-to-end test of cadenway-backup and cadenway-restore against a real PostgreSQL and a local
# S3 endpoint (`rclone serve s3`). Covers: a failed backup keeps the older backups, a good one
# applies the retention, a restore with a missing dump changes nothing, a restore brings the data
# back, drops the tables a later migration added, and starts the stopped service again.
#
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
#     -v "$PWD/ansible/roles/backup:/backup:ro" docker:28.5.2-cli \
#     sh -c "apk add --no-cache bash >/dev/null && bash /backup/tests/e2e.sh"
#
# It creates and removes the containers cw-test-postgres and cw-test-task: never run it on a host.
#
# The assertions are strings evaluated by `check`, so they expand late on purpose.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
apk add --quiet --no-cache bash jq curl age rclone util-linux coreutils >/dev/null
curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
echo "e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b  /usr/local/bin/sops" | sha256sum -c - >/dev/null
chmod +x /usr/local/bin/sops
for script in backup restore; do
  cp "/backup/files/cadenway-$script.sh" "/usr/local/bin/cadenway-$script"
  chmod +x "/usr/local/bin/cadenway-$script"
done
mkdir -p /run/lock /etc/cadenway /data/backups/test

cleanup() { docker rm -f cw-test-postgres cw-test-task >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

PG='postgres:18.6-alpine@sha256:9ba53c7d41ea093baf5c1ba635ba5434c4f979880527d49bb7d9237d3193085b'
docker run -d --name cw-test-postgres -e POSTGRES_PASSWORD=postgres \
  --label com.docker.compose.project=cadenway-test --label com.docker.compose.service=postgres \
  "$PG" >/dev/null
docker run -d --name cw-test-task --label com.docker.compose.project=cadenway-test \
  --label com.docker.compose.service=task-service busybox:1.37.0 sleep infinity >/dev/null
until docker exec cw-test-postgres pg_isready -U postgres -q 2>/dev/null; do sleep 1; done
sleep 2
sql() { docker exec -i cw-test-postgres psql -U postgres -v ON_ERROR_STOP=1 -tAq "$@"; }
sql <<'SQL'
CREATE USER task WITH PASSWORD 'task';
CREATE DATABASE task OWNER task;
SQL
sql -d task <<'SQL'
SET ROLE task;
CREATE TABLE tasks (id text PRIMARY KEY, title text);
INSERT INTO tasks VALUES ('CAD-482', 'Écran SSO');
SQL

# Local S3 endpoint; the bucket is the folder /data/backups.
rclone serve s3 /data --addr 127.0.0.1:9000 --auth-key key,secretkey >/tmp/s3.log 2>&1 &
sleep 2

age-keygen -o /etc/cadenway/age.key 2>/dev/null
age-keygen -o /tmp/backup.key 2>/dev/null
cat >/etc/cadenway/backup.env <<EOF
CADENWAY_ENVIRONMENTS=test
CADENWAY_BACKUP_DATABASES="task missing"
CADENWAY_BACKUP_RECIPIENT=$(age-keygen -y /tmp/backup.key)
CADENWAY_BACKUP_RETENTION_DAYS=30
EOF
mkdir -p /opt/cadenway/envs/test/environments/test
printf '%s\n' BACKUP_S3_ENDPOINT=http://127.0.0.1:9000 BACKUP_S3_REGION=us-east-1 \
  BACKUP_S3_BUCKET=backups BACKUP_S3_ACCESS_KEY_ID=key BACKUP_S3_SECRET_ACCESS_KEY=secretkey \
  ALERT_WEBHOOK_URL= >/tmp/plain.env
sops --encrypt --age "$(age-keygen -y /etc/cadenway/age.key)" --input-type dotenv --output-type dotenv \
  /tmp/plain.env >/opt/cadenway/envs/test/environments/test/secrets.sops.env
rm /tmp/plain.env

# A backup older than the retention.
mkdir -p /data/backups/test/20200101T000000Z
echo old >/data/backups/test/20200101T000000Z/task.dump.age
touch -d '2020-01-01' /data/backups/test/20200101T000000Z/task.dump.age

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
FAILED=0

echo '=== 1. a database fails: the backup fails, older backups stay'
set +e
cadenway-backup 2>/tmp/out
RESULT=$?
set -e
check 'run fails' '[[ $RESULT != 0 ]]'
check 'old backup kept' '[[ -e /data/backups/test/20200101T000000Z/task.dump.age ]]'
check 'no partial object for the failed database' '[[ -z $(find /data/backups/test -name missing.dump.age) ]]'

echo '=== 2. every database saved: retention applies'
sed -i 's/^CADENWAY_BACKUP_DATABASES=.*/CADENWAY_BACKUP_DATABASES="task"/' /etc/cadenway/backup.env
sleep 1
cadenway-backup 2>/tmp/out
STAMP=$(basename "$(dirname "$(find /data/backups/test -name task.dump.age ! -path '*2020*' | sort | tail -1)")")
check 'dump uploaded' '[[ -s /data/backups/test/$STAMP/task.dump.age ]]'
check 'dump encrypted' '! grep -q "CAD-482" /data/backups/test/$STAMP/task.dump.age'
check 'old backup deleted' '[[ ! -e /data/backups/test/20200101T000000Z/task.dump.age ]]'

echo '=== 3. a missing dump: nothing changes'
set +e
cadenway-restore test 20991231T000000Z /tmp/backup.key task 2>/tmp/out
RESULT=$?
set -e
check 'restore fails' '[[ $RESULT != 0 ]]'
check 'data untouched' '[[ $(sql -d task -c "SELECT title FROM tasks") == "Écran SSO" ]]'

echo '=== 4. restore: data back, later tables gone, service started again'
sql -d task <<'SQL'
SET ROLE task;
DELETE FROM tasks;
CREATE TABLE added_by_a_later_migration (id int);
SQL
cadenway-restore test "$STAMP" /tmp/backup.key task 2>/tmp/out
check 'row restored' '[[ $(sql -d task -c "SELECT title FROM tasks") == "Écran SSO" ]]'
check 'later table dropped' '[[ -z $(sql -d task -c "SELECT 1 FROM pg_tables WHERE tablename = '\''added_by_a_later_migration'\''") ]]'
check 'owned by the service user' '[[ $(sql -d task -c "SELECT tableowner FROM pg_tables WHERE tablename = '\''tasks'\''") == task ]]'
check 'service running again' '[[ $(docker inspect -f "{{.State.Running}}" cw-test-task) == true ]]'
check 'no plaintext left' '[[ ! -e /var/lib/cadenway-restore ]]'

exit $FAILED
