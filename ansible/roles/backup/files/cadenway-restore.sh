#!/usr/bin/env bash
# Restores service databases of one environment from a backup made by cadenway-backup.
#
#   cadenway-restore <env> <timestamp> <identity file> [database...]
#
# A backup is restored to a separate database while the old database still serves traffic.
# Only a fully restored candidate with a compatible migration journal can replace it.
# Storage also requires the immutable object keys referenced by its restored metadata.
# The old database is retained with connections disabled after a successful cutover.
# With no database list, restore every backed-up database.
#
# The GitOps agent's lock covers preparation, cutover and recovery. Encrypted dumps and object
# inventories use a private working directory. No plaintext dump or object bytes are written there.
set -euo pipefail

[[ $# -ge 3 ]] || {
  echo "usage: cadenway-restore <env> <timestamp> <identity file> [database...]" >&2
  exit 2
}
readonly ENVIRONMENT=$1 STAMP=$2 IDENTITY=$3
shift 3

[[ $ENVIRONMENT =~ ^[a-z0-9][a-z0-9-]*$ && $STAMP =~ ^[0-9]{8}T[0-9]{6}Z$ && -f $IDENTITY && -r $IDENTITY ]] || {
  echo "invalid environment, timestamp or backup identity path" >&2
  exit 2
}

set -a
# shellcheck source=/dev/null
source /etc/cadenway/backup.env
set +a
export SOPS_AGE_KEY_FILE=/etc/cadenway/age.key

secret() { sed -n "s/^$2=//p" <<<"$1" | tail -n 1; }

containers_of() {
  docker ps -q --filter "label=com.docker.compose.project=cadenway-$ENVIRONMENT" \
    --filter "label=com.docker.compose.service=$1"
}

psql_on() {
  local container=$1 database=$2
  shift 2
  docker exec -i "$container" psql --quiet --no-psqlrc --username=postgres \
    --dbname="$database" --set=ON_ERROR_STOP=1 "$@"
}

database_oid() {
  psql_on "$1" postgres --no-align --tuples-only --set=name="$2" <<'SQL'
SELECT oid FROM pg_database WHERE datname = :'name';
SQL
}

migration_journal() {
  psql_on "$1" "$2" --no-align --tuples-only <<'SQL'
SELECT to_regclass('drizzle.__drizzle_migrations') IS NOT NULL AS has_journal \gset
\if :has_journal
  SELECT coalesce(jsonb_agg(jsonb_build_array(hash, created_at) ORDER BY id), '[]'::jsonb)
  FROM drizzle.__drizzle_migrations;
\else
  SELECT 'no journal';
\endif
SQL
}

# List durable object references from the candidate while only the restore operator can connect.
storage_object_manifest() {
  psql_on "$1" "$2" --no-align --tuples-only <<'SQL'
BEGIN READ ONLY;
SELECT json_build_object('key', object_key, 'size', size_bytes)
FROM (
  SELECT attachment.elected_object_key AS object_key, attachment.size_bytes
  FROM public.attachments AS attachment
  WHERE attachment.status = 'ready' AND attachment.scan_status = 'verified'
    AND NOT EXISTS (
      SELECT 1
      FROM public.attachment_task_tombstones AS task
      WHERE task.organization_id = attachment.organization_id
        AND task.task_key = attachment.task_key
        AND task.purged_at IS NOT NULL
    )
  UNION ALL
  SELECT candidate_key, size_bytes
  FROM public.intake_attachments
  WHERE status = 'verified'
  UNION ALL
  SELECT 'profile-media/candidate/' || upload.candidate_id::text, upload.derivative_size_bytes
  FROM public.profile_media_uploads AS upload
  JOIN public.profile_media_owners AS owner USING (owner_kind, owner_id)
  WHERE upload.status IN ('prepared', 'attached') AND NOT owner.deleted
) AS objects;
COMMIT;
SQL
}

restore_storage_objects() (
  local field setting value
  unset RCLONE_CONFIG_BACKUP_{TYPE,PROVIDER,ENDPOINT,REGION,ACCESS_KEY_ID,SECRET_ACCESS_KEY}
  unset RESTORE_OBJECT_S3_FORCE_PATH_STYLE
  for field in ENDPOINT REGION BUCKET ACCESS_KEY_ID SECRET_ACCESS_KEY; do
    case $field in
      ACCESS_KEY_ID | SECRET_ACCESS_KEY) setting="STORAGE_RESTORE_S3_$field" ;;
      *) setting="STORAGE_S3_$field" ;;
    esac
    value=$(secret "$plain" "$setting") || return 1
    if [[ -z $value ]]; then
      echo "$ENVIRONMENT: $setting is required to restore referenced Storage objects" >&2
      return 1
    fi
    export "RESTORE_OBJECT_S3_$field=$value"
  done
  value=$(secret "$plain" STORAGE_S3_FORCE_PATH_STYLE) || return 1
  if [[ -n $value ]]; then export RESTORE_OBJECT_S3_FORCE_PATH_STYLE="$value"; fi
  /usr/bin/python3 /usr/local/lib/cadenway/cadenway-restore-objects.py "$@"
)

# Verify the stopped state explicitly because this function is called in conditionals.
stop_group() {
  local grace=$1 id state
  shift
  (($# > 0)) || return 0
  docker stop --time "$grace" "$@" >/dev/null || return 1
  for id in "$@"; do
    state=$(docker inspect --format '{{.State.Running}}' "$id") || return 1
    [[ $state == false ]] || return 1
  done
}

# Wait for the configured health check. Containers without a check must at least stay running.
start_group() {
  local id state deadline=$((SECONDS + 120))
  (($# > 0)) || return 0
  docker start "$@" >/dev/null || return 1
  for id in "$@"; do
    while :; do
      state=$(docker inspect --format '{{if and .State.Running .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$id") || return 1
      case $state in
        healthy | running) break ;;
        starting) ;;
        *) return 1 ;;
      esac
      ((SECONDS < deadline)) || return 1
      sleep 1
    done
  done
}

# RENAME refuses a database with other sessions. A direct client still connected after
# the known users have stopped aborts the entire transaction without renaming either database.
switch_databases() {
  psql_on "$1" postgres --set=live="$2" --set=ready="$3" --set=parked="$4" --set=has_live="$5" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
SET LOCAL synchronous_commit = on;
\if :has_live
  ALTER DATABASE :"live" RENAME TO :"parked";
  ALTER DATABASE :"parked" WITH ALLOW_CONNECTIONS false;
\endif
ALTER DATABASE :"ready" RENAME TO :"live";
ALTER DATABASE :"live" WITH ALLOW_CONNECTIONS true;
COMMIT;
SQL
}

withdraw_candidate() {
  psql_on "$1" postgres --set=live="$2" --set=candidate="$3" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
SET LOCAL synchronous_commit = on;
ALTER DATABASE :"live" RENAME TO :"candidate";
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS false;
COMMIT;
SQL
}

# This subshell keeps the recovery state for one database separate from the next restore.
restore_database() (
  local pg_container=$1 db_name=$2
  local candidate_db=cw_restore_candidate_${db_name}_${WORK##*.}
  local previous_db=cw_restore_previous_${db_name}_${WORK##*.}
  local failed_db=cw_restore_failed_${db_name}_${WORK##*.}
  local original_oid new_oid='' live_oid current_journal candidate_journal ids companion has_original=false
  local object_manifest object_plan=''
  local candidate_created=false service_stop_attempted=false cutover_attempted=false
  local -a owners=() companions=()
  umask 077

  original_oid=$(database_oid "$pg_container" "$db_name") || return 1

  resume_services() {
    start_group "${owners[@]}" && start_group "${companions[@]}"
  }

  stop_services() {
    stop_group 60 "${companions[@]}" && stop_group 30 "${owners[@]}"
  }

  # Called by the EXIT trap via finish_restore.
  # shellcheck disable=SC2329
  recover_services() {
    local active_oid retained_oid failed_oid
    if [[ $cutover_attempted == true ]]; then
      # A failed client call can still mean COMMIT succeeded. Resolve using the OIDs
      # before deciding which database to serve or discard.
      active_oid=$(database_oid "$pg_container" "$db_name") || return 1
      if [[ $active_oid == "$new_oid" ]]; then
        if [[ $has_original == true ]]; then
          retained_oid=$(database_oid "$pg_container" "$previous_db") || return 1
          [[ $retained_oid == "$original_oid" ]] || return 1
        fi
        stop_services || return 1
        if [[ $has_original == true ]]; then
          switch_databases "$pg_container" "$db_name" "$previous_db" "$failed_db" true || true
        else
          withdraw_candidate "$pg_container" "$db_name" "$failed_db" || true
        fi
        active_oid=$(database_oid "$pg_container" "$db_name") || return 1
        failed_oid=$(database_oid "$pg_container" "$failed_db") || return 1
        [[ $active_oid == "$original_oid" && $failed_oid == "$new_oid" ]] || return 1
        # The candidate could have served writes while its companion was starting.
        echo "$ENVIRONMENT: previous database name recovered; inspect $failed_db for writes accepted during the cutover" >&2
      fi
      [[ $active_oid == "$original_oid" ]] || return 1
    fi
    resume_services
  }

  # Called by the EXIT trap.
  # shellcheck disable=SC2329
  finish_restore() {
    local status=$1 discarded_oid
    ((status != 0)) || return 0
    if [[ $service_stop_attempted == true ]] && ! recover_services; then
      echo "$ENVIRONMENT: recovery of $db_name could not be verified; preserving databases for inspection" >&2
      echo "$ENVIRONMENT: inspect $db_name, $previous_db, $candidate_db and $failed_db before resuming service" >&2
      return "$status"
    fi
    if [[ $candidate_created == true ]]; then
      if ! discarded_oid=$(database_oid "$pg_container" "$candidate_db"); then
        echo "$ENVIRONMENT: could not inspect candidate $candidate_db for cleanup" >&2
      elif [[ -n $new_oid && $discarded_oid == "$new_oid" ]]; then
        if ! psql_on "$pg_container" postgres --set=name="$candidate_db" <<'SQL'
DROP DATABASE :"name";
SQL
        then
          echo "$ENVIRONMENT: candidate $candidate_db still needs cleanup" >&2
        fi
      elif [[ -z $new_oid || -n $discarded_oid ]]; then
        echo "$ENVIRONMENT: could not verify candidate ownership for cleanup of $candidate_db" >&2
      fi
    fi
    return "$status"
  }

  trap 'finish_restore "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  psql_on "$pg_container" postgres --set=candidate="$candidate_db" --set=migrator="${db_name}_migrator" <<'SQL' ||
CREATE DATABASE :"candidate" WITH OWNER :"migrator" ALLOW_CONNECTIONS false;
SQL
    return 1
  candidate_created=true
  new_oid=$(database_oid "$pg_container" "$candidate_db") || return 1
  [[ -n $new_oid ]] || return 1
  psql_on "$pg_container" postgres --set=candidate="$candidate_db" <<'SQL' || return 1
BEGIN;
REVOKE ALL ON DATABASE :"candidate" FROM PUBLIC;
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS true;
COMMIT;
SQL

  if ! age --decrypt --identity "$IDENTITY" "$WORK/$db_name.dump.age" |
    docker exec -i "$pg_container" pg_restore --username=postgres --exit-on-error \
      --no-owner --role="${db_name}_migrator" --dbname="$candidate_db"; then
    echo "$ENVIRONMENT: the dump of $db_name could not be restored to the candidate; the live database was untouched" >&2
    return 1
  fi

  candidate_journal=$(migration_journal "$pg_container" "$candidate_db") || return 1
  if [[ -n $original_oid ]]; then
    has_original=true
    current_journal=$(migration_journal "$pg_container" "$db_name") || return 1
    if [[ $current_journal != "$candidate_journal" ]]; then
      echo "$ENVIRONMENT: $db_name migration journal differs; align the application and backup before restoring" >&2
      return 1
    fi
  else
    echo "$ENVIRONMENT: no existing $db_name database to compare; verifying the recovered service through health checks" >&2
  fi
  if [[ $db_name == storage ]]; then
    object_manifest=$(mktemp "$WORK/storage-objects.XXXXXXXX") || return 1
    if ! storage_object_manifest "$pg_container" "$candidate_db" >"$object_manifest"; then
      echo "$ENVIRONMENT: could not inventory Storage objects from the restored schema" >&2
      return 1
    fi
    if [[ -s $object_manifest ]]; then
      object_plan=$object_manifest.plan
      if ! restore_storage_objects plan "$object_manifest" "$object_plan"; then
        echo "$ENVIRONMENT: Storage object preflight failed; the live database was untouched" >&2
        return 1
      fi
    fi
  fi
  psql_on "$pg_container" postgres --set=candidate="$candidate_db" --set=app="${db_name}_app" <<'SQL' ||
BEGIN;
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS false;
GRANT CONNECT ON DATABASE :"candidate" TO :"app";
COMMIT;
SQL
    return 1

  ids=$(containers_of "$db_name-service") || return 1
  if [[ -n $ids ]]; then mapfile -t owners <<<"$ids"; fi
  # The GitOps agent's allowlisted companions share their owner's application database.
  case $db_name in
    task) companion=task-service-relay ;;
    notification) companion=notification-service-worker ;;
    *) companion='' ;;
  esac
  if [[ -n $companion ]]; then
    ids=$(containers_of "$companion") || return 1
    if [[ -n $ids ]]; then mapfile -t companions <<<"$ids"; fi
  fi

  service_stop_attempted=true
  if ! stop_services; then
    echo "$ENVIRONMENT: could not stop every user of $db_name; keeping the original database" >&2
    return 1
  fi
  if [[ -n $object_plan ]] && ! restore_storage_objects apply "$object_plan"; then
    echo "$ENVIRONMENT: Storage object recovery failed before cutover; keeping the original database" >&2
    return 1
  fi
  cutover_attempted=true
  if ! switch_databases "$pg_container" "$db_name" "$candidate_db" "$previous_db" "$has_original" ||
    ! live_oid=$(database_oid "$pg_container" "$db_name") ||
    [[ $live_oid != "$new_oid" ]]; then
    echo "$ENVIRONMENT: could not verify the cutover of $db_name" >&2
    return 1
  fi
  if ! resume_services; then
    echo "$ENVIRONMENT: restored $db_name did not start with healthy services; recovering the prior state" >&2
    return 1
  fi
  if [[ $has_original == true ]]; then
    echo "$ENVIRONMENT: $db_name restored from $STAMP; prior database retained as $previous_db" >&2
  else
    echo "$ENVIRONMENT: $db_name restored from $STAMP" >&2
  fi
)

main() {
  local plain postgres database name bucket status=0 result
  local -a databases=("$@")
  (("${#databases[@]}")) || read -r -a databases <<<"$CADENWAY_BACKUP_DATABASES"
  for database in "${databases[@]}"; do
    [[ $database =~ ^[a-z][a-z0-9_]{0,24}$ && $database != postgres && $database != template0 && $database != template1 ]] || {
      echo "invalid service database name" >&2
      return 2
    }
  done

  # Wait for a running deployment and prevent new rollouts until recovery is complete.
  exec 9>/run/lock/cadenway-agent.lock
  flock -w 900 9 || {
    echo "the GitOps agent kept its lock for 15 minutes; try again" >&2
    return 1
  }
  WORK=$(mktemp -d /var/lib/cadenway-restore.XXXXXXXX)
  readonly WORK
  trap 'rm -rf -- "$WORK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  plain=$(sops --decrypt --input-type dotenv --output-type dotenv \
    "/opt/cadenway/envs/$ENVIRONMENT/environments/$ENVIRONMENT/secrets.sops.env")
  export RCLONE_CONFIG_BACKUP_TYPE=s3 RCLONE_CONFIG_BACKUP_PROVIDER=Other
  for name in ENDPOINT REGION ACCESS_KEY_ID SECRET_ACCESS_KEY; do
    export "RCLONE_CONFIG_BACKUP_$name=$(secret "$plain" "BACKUP_S3_$name")"
  done
  bucket=$(secret "$plain" BACKUP_S3_BUCKET)
  [[ -n $bucket ]] || {
    echo "BACKUP_S3_BUCKET is missing from the secrets of $ENVIRONMENT" >&2
    return 1
  }

  postgres=$(containers_of postgres)
  [[ $postgres =~ ^[0-9a-f]{12,64}$ ]] || {
    echo "$ENVIRONMENT: expected exactly one running PostgreSQL container" >&2
    return 1
  }
  for database in "${databases[@]}"; do
    if ! rclone copyto "backup:$bucket/$ENVIRONMENT/$STAMP/$database.dump.age" "$WORK/$database.dump.age"; then
      echo "$ENVIRONMENT: the dump of $database is missing or unreadable; nothing was changed" >&2
      status=1
      continue
    fi
    result=0
    restore_database "$postgres" "$database" || result=$?
    rm -f -- "$WORK/$database.dump.age"
    if ((result >= 128)); then return "$result"; fi
    if ((result != 0)); then
      echo "$ENVIRONMENT: restoring $database failed" >&2
      status=1
    fi
  done
  return "$status"
}

main "$@"
