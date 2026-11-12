#!/usr/bin/env bash
# Restores service databases of one environment from a backup made by cadenway-backup.
#
#   cadenway-restore <env> <timestamp> <identity file> [database...]
#
# For each database: the encrypted dump is downloaded and checked first; only then is the service
# stopped, its database dropped and created again empty (so tables added by later migrations do not
# survive next to an older migration journal), the dump restored, and the service started again.
# Without a database list, every backed-up database is restored.
#
# The GitOps agent's lock is held for the whole restore: no deployment, migration or restart runs
# meanwhile. The identity (the backup private key) is read from the given file only; the restore
# playbook copies it to /run and removes it whatever the outcome.
set -euo pipefail

[[ $# -ge 3 ]] || {
  echo "usage: cadenway-restore <env> <timestamp> <identity file> [database...]" >&2
  exit 2
}
readonly ENVIRONMENT=$1 STAMP=$2 IDENTITY=$3
shift 3

set -a
# shellcheck source=/dev/null
source /etc/cadenway/backup.env
set +a
export SOPS_AGE_KEY_FILE=/etc/cadenway/age.key

readonly WORK=/var/lib/cadenway-restore
trap 'rm -rf "$WORK"' EXIT

secret() { sed -n "s/^$2=//p" <<<"$1" | tail -n 1; }

containers_of() {
  docker ps -q --filter "label=com.docker.compose.project=cadenway-$ENVIRONMENT" \
    --filter "label=com.docker.compose.service=$1"
}

# Restores one database from its downloaded, still encrypted dump.
restore_database() {
  local postgres=$1 database=$2 dump=$WORK/$2.dump.age
  local -a stopped
  mapfile -t stopped < <(containers_of "$database-service")
  if ((${#stopped[@]})); then docker stop --time 30 "${stopped[@]}" >/dev/null; fi
  local status=0
  docker exec -i "$postgres" psql --quiet --username=postgres --set=ON_ERROR_STOP=1 \
    --set=db="$database" --file=- <<'SQL' || status=1
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db" OWNER :"db";
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
SQL
  if ((status == 0)); then
    age --decrypt --identity "$IDENTITY" "$dump" |
      docker exec -i "$postgres" pg_restore --username=postgres --exit-on-error \
        --no-owner --role="$database" --dbname="$database" || status=1
  fi
  # The service comes back whatever the outcome: the agent does not restart a stopped container.
  if ((${#stopped[@]})); then docker start "${stopped[@]}" >/dev/null; fi
  return "$status"
}

main() {
  local plain postgres database name bucket status=0
  local -a databases=("$@")
  ((${#databases[@]})) || read -r -a databases <<<"$CADENWAY_BACKUP_DATABASES"

  # Waits for a running deployment to finish, then keeps the agent out until the restore ends.
  exec 9>/run/lock/cadenway-agent.lock
  flock -w 900 9 || {
    echo "the GitOps agent kept its lock for 15 minutes; try again" >&2
    exit 1
  }

  plain=$(sops --decrypt --input-type dotenv --output-type dotenv \
    "/opt/cadenway/envs/$ENVIRONMENT/environments/$ENVIRONMENT/secrets.sops.env")
  export RCLONE_CONFIG_BACKUP_TYPE=s3 RCLONE_CONFIG_BACKUP_PROVIDER=Other
  for name in ENDPOINT REGION ACCESS_KEY_ID SECRET_ACCESS_KEY; do
    export "RCLONE_CONFIG_BACKUP_$name=$(secret "$plain" "BACKUP_S3_$name")"
  done
  bucket=$(secret "$plain" BACKUP_S3_BUCKET)
  [[ -n $bucket ]] || {
    echo "BACKUP_S3_BUCKET is missing from the secrets of $ENVIRONMENT" >&2
    exit 1
  }

  postgres=$(containers_of postgres)
  [[ -n $postgres ]] || {
    echo "$ENVIRONMENT: PostgreSQL is not running" >&2
    exit 1
  }

  install -d -m 0700 "$WORK"
  for database in "${databases[@]}"; do
    # Download and check the whole dump before touching the live database.
    if ! rclone copyto "backup:$bucket/$ENVIRONMENT/$STAMP/$database.dump.age" \
      "$WORK/$database.dump.age" ||
      ! age --decrypt --identity "$IDENTITY" "$WORK/$database.dump.age" |
      docker exec -i "$postgres" pg_restore --list >/dev/null; then
      echo "$ENVIRONMENT: the dump of $database is missing or unreadable; nothing was changed" >&2
      status=1
      continue
    fi
    if restore_database "$postgres" "$database"; then
      echo "$ENVIRONMENT: $database restored from $STAMP" >&2
    else
      echo "$ENVIRONMENT: restoring $database FAILED; its database may be empty" >&2
      status=1
    fi
    rm -f "$WORK/$database.dump.age"
  done
  return "$status"
}

main "$@"
