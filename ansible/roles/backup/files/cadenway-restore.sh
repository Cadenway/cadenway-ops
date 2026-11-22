#!/usr/bin/env bash
# Restores service databases of one environment from a backup made by cadenway-backup.
#
#   cadenway-restore [--rebuild-task-memberships] <env> <timestamp> <identity file> [database...]
#   cadenway-restore --recover <env>
#
# Each archive is authenticated before any database is created or modified. A backup is restored
# to a separate database while the old database still serves traffic.
# Only a fully restored candidate with a compatible migration journal can replace it.
# Storage also requires the immutable object keys referenced by its restored metadata.
# The old database is retained with connections disabled after a successful cutover.
# With no database list, restore every backed-up database.
#
# The GitOps agent's lock covers preparation, cutover and recovery. Encrypted dumps and object
# inventories use a private working directory. No plaintext dump or object bytes are written there.
set -euo pipefail

readonly ALLOWED_SIGNERS=/etc/cadenway/backup-allowed-signers
readonly SIGNING_NAMESPACE=cadenway-backup-manifest-v1
readonly MAX_MANIFEST_SIZE=8192
readonly LOCK_FILE=${CADENWAY_LOCK_FILE:-/run/lock/cadenway-agent.lock}
readonly AGENT_STATE=${CADENWAY_STATE_DIR:-/var/lib/cadenway-agent}
readonly RESTORE_STATE=$AGENT_STATE/restore

secret() { sed -n "s/^$2=//p" <<<"$1" | tail -n 1; }

# Download only the generation named by a trusted manifest. Bound untrusted reads to the
# manifest limit and signed ciphertext length before verifying the exact bytes on disk.
download_verified_archive() {
  local bucket=$1 database=$2 prefix digest size manifest signature envelope archive object actual
  prefix="$ENVIRONMENT/$STAMP/$database"
  envelope="$WORK/$database.signed-manifest"
  manifest="$WORK/$database.manifest"
  signature="$WORK/$database.signature"
  archive="$WORK/$database.dump.age"

  if ! rclone cat --head "$((MAX_MANIFEST_SIZE + 1))" "backup:$bucket/$prefix.manifest.json" >"$envelope" ||
    (($(wc -c <"$envelope") > MAX_MANIFEST_SIZE)) ||
    ! jq -erj '.manifest | strings | select(length > 0)' "$envelope" >"$manifest" ||
    ! jq -erj '.signature | strings | select(length > 0)' "$envelope" >"$signature" ||
    ! ssh-keygen -Y verify -f "$ALLOWED_SIGNERS" -I cadenway-backup -n "$SIGNING_NAMESPACE" \
      -s "$signature" <"$manifest" >/dev/null; then
    echo "$ENVIRONMENT: no trusted backup manifest for $database; nothing was changed" >&2
    return 1
  fi

  if ! jq -e --arg env "$ENVIRONMENT" --arg stamp "$STAMP" --arg database "$database" --arg bucket "$bucket" \
    '.version == 1 and .env == $env and .stamp == $stamp and .database == $database and .bucket == $bucket' \
    "$manifest" >/dev/null ||
    ! digest=$(jq -er '.sha256 | strings | select(test("^[0-9a-f]{64}$"))' "$manifest") ||
    ! size=$(jq -er '.size | numbers | select(. == floor and . > 0 and . < 9007199254740991)' "$manifest"); then
    echo "$ENVIRONMENT: signed backup manifest has invalid scope or metadata for $database" >&2
    return 1
  fi

  object="$prefix-$digest.dump.age"
  if ! jq -e --arg object "$object" '.object == $object' "$manifest" >/dev/null ||
    ! rclone cat --head "$((size + 1))" "backup:$bucket/$object" >"$archive" ||
    (($(wc -c <"$archive") != size)) ||
    ! actual=$(sha256sum <"$archive") || [[ ${actual%% *} != "$digest" ]]; then
    echo "$ENVIRONMENT: encrypted archive does not match the signed manifest for $database; nothing was changed" >&2
    rm -f -- "$archive"
    return 1
  fi
}

containers_of() {
  docker ps --no-trunc -q --filter "label=com.docker.compose.project=cadenway-$ENVIRONMENT" \
    --filter "label=com.docker.compose.service=$1"
}

companion_of() {
  case $1 in
    task) printf '%s' task-service-relay ;;
    notification) printf '%s' notification-service-worker ;;
  esac
}

valid_database_name() {
  [[ $1 =~ ^[a-z][a-z0-9_]{0,24}$ && $1 != postgres && $1 != template0 && $1 != template1 ]]
}

psql_as() {
  local container=$1 database=$2 role=$3
  shift 3
  docker exec -i "$container" psql --quiet --no-psqlrc --username="$role" --no-password \
    --dbname="$database" --set=ON_ERROR_STOP=1 "$@"
}

database_oid() {
  psql_as "$1" postgres postgres --no-align --tuples-only --set=name="$2" <<'SQL'
SELECT oid FROM pg_database WHERE datname = :'name';
SQL
}

database_location() {
  psql_as "$1" postgres postgres --no-align --tuples-only --set=name="$2" <<'SQL'
SELECT oid::text || ':' || CASE WHEN datallowconn THEN 'open' ELSE 'closed' END
FROM pg_database WHERE datname = :'name';
SQL
}

migration_journal() {
  psql_as "$1" "$2" "$3" --no-align --tuples-only <<'SQL'
BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog;
SELECT to_regclass('drizzle.__drizzle_migrations') IS NOT NULL AS has_journal \gset
\if :has_journal
  SELECT coalesce(jsonb_agg(jsonb_build_array(hash, created_at) ORDER BY id), '[]'::jsonb)
  FROM drizzle.__drizzle_migrations;
\else
  SELECT 'no journal';
\endif
COMMIT;
SQL
}

# Read restored objects under the service role, with the system policy required by its RLS.
storage_object_manifest() {
  psql_as "$1" "$2" storage_migrator --no-align --tuples-only <<'SQL'
BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog;
SET LOCAL app.system_access = 'on';
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
  psql_as "$1" postgres postgres --set=live="$2" --set=ready="$3" --set=parked="$4" \
    --set=live_oid="$5" --set=ready_oid="$6" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
SET LOCAL synchronous_commit = on;
SELECT :'live_oid' <> '' AS has_live \gset
\if :has_live
  ALTER DATABASE :"live" RENAME TO :"parked";
  ALTER DATABASE :"parked" WITH ALLOW_CONNECTIONS false;
\endif
ALTER DATABASE :"ready" RENAME TO :"live";
ALTER DATABASE :"live" WITH ALLOW_CONNECTIONS true;
-- Confirm the identities after acquiring the rename locks and before COMMIT.
SELECT 1 / CASE WHEN (
  (SELECT oid::text FROM pg_database WHERE datname = :'live') = :'ready_oid'
  AND coalesce((SELECT oid::text FROM pg_database WHERE datname = :'parked'), '') = :'live_oid'
) THEN 1 ELSE 0 END AS verified \gset
COMMIT;
SQL
}

withdraw_candidate() {
  psql_as "$1" postgres postgres --set=live="$2" --set=candidate="$3" --set=candidate_oid="$4" <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
SET LOCAL synchronous_commit = on;
ALTER DATABASE :"live" RENAME TO :"candidate";
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS false;
SELECT 1 / CASE WHEN (
  (SELECT oid::text FROM pg_database WHERE datname = :'candidate') = :'candidate_oid'
) THEN 1 ELSE 0 END AS verified \gset
COMMIT;
SQL
}

verify_group() {
  local service=$1 id metadata running IFS=' '
  shift
  for id in "$@"; do
    metadata=$(docker inspect --format '{{.Id}} {{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}} {{with index .Config.Labels "com.docker.compose.oneoff"}}{{.}}{{end}}' "$id") || return 1
    case $metadata in
      "$id cadenway-$ENVIRONMENT $service " | "$id cadenway-$ENVIRONMENT $service false" | "$id cadenway-$ENVIRONMENT $service False") ;;
      *) return 1 ;;
    esac
  done
  [[ -n $service ]] || return 0
  running=$(containers_of "$service") || return 1
  while IFS= read -r id; do
    [[ -z $id || " $* " == *" $id "* ]] || return 1
  done <<<"$running"
}

membership_importer_name() {
  printf 'cadenway-%s-restore-memberships-%s' "$ENVIRONMENT" "$1"
}

# A pending journal can outlive the importer client. Only remove the dedicated container
# bearing this restore's labels before closing or discarding its candidate database.
remove_membership_importer() {
  local name id metadata
  name=$(membership_importer_name "$1")
  id=$(docker ps -a --no-trunc -q --filter "name=^/$name$") || return 1
  [[ -n $id ]] || return 0
  [[ $id =~ ^[0-9a-f]{64}$ ]] || return 1
  metadata=$(docker inspect --format '{{.Id}} {{.Name}} {{index .Config.Labels "com.cadenway.restore.environment"}} {{index .Config.Labels "com.cadenway.restore.candidate"}}' "$id") ||
    return 1
  [[ $metadata == "$id /$name $ENVIRONMENT $1" ]] || return 1
  docker rm -f "$id" >/dev/null
}

set_candidate_connections() {
  psql_as "$1" postgres postgres --set=candidate="$2" --set=accept="$3" <<'SQL'
\if :accept
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS true;
\else
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS false;
\endif
SQL
}

# Only the application URL is passed to the exact Task image already on the host. The stream
# contains membership data, so leave it on the pipe and suppress the importer's standard output.
rebuild_task_memberships() {
  local postgres=$1 candidate=$2 suffix=$3 source=$4 task=$5 image network name database_url
  image=$(docker inspect --format '{{.Image}}' "$task") || return 1
  [[ $image =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  network=$(docker network ls --no-trunc -q --filter "label=com.docker.compose.project=cadenway-$ENVIRONMENT" \
    --filter 'label=com.docker.compose.network=internal') || return 1
  [[ $network =~ ^[0-9a-f]{64}$ ]] || return 1
  if [[ $(docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$postgres") != "$network" ]]; then
    return 1
  fi
  database_url=$(secret "$plain" TASK_SERVICE_DATABASE_URL) || return 1
  [[ -n $database_url ]] || return 1

  verify_group organization-service "$source" || return 1
  name=$(membership_importer_name "$suffix")
  set_candidate_connections "$postgres" "$candidate" true || return 1
  if ! docker exec "$source" node --import @cadenway/nest-common/register \
    dist/modules/organizations/infrastructure/adapters/membership-export/export-memberships.js |
    DATABASE_URL="$database_url" docker run --pull never --rm --init --interactive --name "$name" --network "$network" \
      --label "com.cadenway.restore.environment=$ENVIRONMENT" --label "com.cadenway.restore.candidate=$suffix" \
      --cap-drop ALL --security-opt no-new-privileges --log-driver none --env DATABASE_URL \
      --entrypoint node "$image" --import @cadenway/nest-common/register \
      dist/infrastructure/maintenance/rebuild-memberships.js --database "$candidate" >/dev/null; then
    return 1
  fi
  set_candidate_connections "$postgres" "$candidate" false
}

write_restore_journal() (
  local journal=$1 temporary
  umask 077
  install -d -m 0700 "$RESTORE_STATE" || return 1
  temporary=$(mktemp "$RESTORE_STATE/.journal.XXXXXXXX") || return 1
  if ! printf '%s\n' "$journal" >"$temporary" || ! sync -f "$temporary" ||
    ! mv -T -- "$temporary" "$RESTORE_JOURNAL"; then
    rm -f -- "$temporary"
    return 1
  fi
  sync -f "$RESTORE_STATE"
)

remove_restore_journal() {
  rm -- "$RESTORE_JOURNAL" && sync -f "$RESTORE_STATE"
}

id_list_json() {
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

validate_restore_journal() {
  [[ -f $RESTORE_JOURNAL && ! -L $RESTORE_JOURNAL ]] &&
    (($(wc -c <"$RESTORE_JOURNAL") <= 65536)) &&
    jq -es --arg environment "$ENVIRONMENT" '
      def id: type == "string" and test("^[0-9a-f]{64}$");
      def oid: type == "string" and test("^[1-9][0-9]{0,9}$");
      def ids: type == "array" and all(.[]; id);
      length == 1 and (.[0] |
        .version == 1 and .environment == $environment
        and (.postgres | id)
        and (.database | type == "string" and test("^[a-z][a-z0-9_]{0,24}$"))
        and (.suffix | type == "string" and test("^[A-Za-z0-9]{8}$"))
        and (.phase == "pending" or .phase == "committed")
        and (.original_oid == "" or (.original_oid | oid))
        and (.candidate_oid | oid) and .original_oid != .candidate_oid
        and (.owners | ids) and (.companions | ids)
        and (if has("rebuild_memberships") then
          (.rebuild_memberships | type == "boolean") and
          (if .rebuild_memberships then .database == "task" else true end)
        else true end)
        and (([.postgres] + .owners + .companions) as $all | ($all | length) == ($all | unique | length))
      )
    ' "$RESTORE_JOURNAL" >/dev/null
}

# Read catalog identities in one PostgreSQL statement so every decision describes one snapshot.
read_restore_locations() {
  psql_as "$1" postgres postgres --no-align --tuples-only \
    --set=live="$2" --set=candidate="$3" --set=previous="$4" --set=failed="$5" <<'SQL'
SELECT coalesce(string_agg(
  format('%s=%s:%s', targets.label, pg_database.oid, CASE WHEN datallowconn THEN 'open' ELSE 'closed' END),
  ' ' ORDER BY targets.position
) FILTER (WHERE pg_database.oid IS NOT NULL), '')
FROM (VALUES (1, 'live', :'live'), (2, 'candidate', :'candidate'),
  (3, 'previous', :'previous'), (4, 'failed', :'failed')) AS targets(position, label, name)
LEFT JOIN pg_database ON datname = targets.name;
SQL
}

recover_restore() {
  [[ -e $RESTORE_JOURNAL || -L $RESTORE_JOURNAL ]] || return 0
  local postgres database suffix candidate previous failed original_oid candidate_oid phase
  local original_layout restored_layout before_layout failed_layout locations group rebuild_memberships
  local -a owners=() companions=()
  validate_restore_journal || return 1
  postgres=$(jq -er .postgres "$RESTORE_JOURNAL") || return 1
  database=$(jq -er .database "$RESTORE_JOURNAL") || return 1
  suffix=$(jq -er .suffix "$RESTORE_JOURNAL") || return 1
  phase=$(jq -er .phase "$RESTORE_JOURNAL") || return 1
  rebuild_memberships=$(jq -r '.rebuild_memberships // false' "$RESTORE_JOURNAL") || return 1
  original_oid=$(jq -er .original_oid "$RESTORE_JOURNAL") || return 1
  candidate_oid=$(jq -er .candidate_oid "$RESTORE_JOURNAL") || return 1
  valid_database_name "$database" || return 1
  group=$(jq -er '.owners | join("\n")' "$RESTORE_JOURNAL") || return 1
  if [[ -n $group ]]; then mapfile -t owners <<<"$group"; fi
  group=$(jq -er '.companions | join("\n")' "$RESTORE_JOURNAL") || return 1
  if [[ -n $group ]]; then mapfile -t companions <<<"$group"; fi
  verify_group postgres "$postgres" &&
    verify_group "$database-service" "${owners[@]}" &&
    verify_group "$(companion_of "$database")" "${companions[@]}" || return 1

  candidate=cw_restore_candidate_${database}_${suffix}
  previous=cw_restore_previous_${database}_${suffix}
  failed=cw_restore_failed_${database}_${suffix}
  if [[ $phase == pending && $rebuild_memberships == true ]]; then
    remove_membership_importer "$suffix" || return 1
  fi
  locations=$(read_restore_locations "$postgres" "$database" "$candidate" "$previous" "$failed") || return 1
  original_layout=''
  restored_layout="live=$candidate_oid:open"
  if [[ -n $original_oid ]]; then
    original_layout="live=$original_oid:open"
    restored_layout+=" previous=$original_oid:closed"
  fi
  before_layout="${original_layout:+$original_layout }candidate=$candidate_oid:closed"
  failed_layout="${original_layout:+$original_layout }failed=$candidate_oid:closed"

  if [[ $phase == committed ]]; then
    [[ $locations == "$restored_layout" ]] || return 1
    start_group "${owners[@]}" && start_group "${companions[@]}" || return 1
  else
    if [[ $rebuild_memberships == true && $locations == "${original_layout:+$original_layout }candidate=$candidate_oid:open" ]]; then
      set_candidate_connections "$postgres" "$candidate" false || return 1
      locations=$(read_restore_locations "$postgres" "$database" "$candidate" "$previous" "$failed") || return 1
    fi
    if [[ $locations == "$restored_layout" ]]; then
      stop_group 60 "${companions[@]}" && stop_group 30 "${owners[@]}" || return 1
      # COMMIT can succeed even if its client exits with an error. Verify by OID afterwards.
      if [[ -n $original_oid ]]; then
        switch_databases "$postgres" "$database" "$previous" "$failed" "$candidate_oid" "$original_oid" || true
      else
        withdraw_candidate "$postgres" "$database" "$failed" "$candidate_oid" || true
      fi
      locations=$(read_restore_locations "$postgres" "$database" "$candidate" "$previous" "$failed") || return 1
      [[ $locations == "$failed_layout" ]] || return 1
    fi
    case $locations in
      "$before_layout")
        if ! psql_as "$postgres" postgres postgres --set=name="$candidate" <<'SQL'
SET lock_timeout = '5s';
SET statement_timeout = '30s';
DROP DATABASE :"name";
SQL
        then
          return 1
        fi
        ;;
      "$failed_layout")
        echo "$ENVIRONMENT: recovered prior name for $database and retained $failed for inspection" >&2
        ;;
      "$original_layout") ;;
      *) return 1 ;;
    esac
    # A cold rollback restores an absent live database, with its associated workloads stopped.
    if [[ -n $original_oid ]]; then
      start_group "${owners[@]}" && start_group "${companions[@]}" || return 1
    else
      stop_group 60 "${companions[@]}" && stop_group 30 "${owners[@]}" || return 1
    fi
  fi
  remove_restore_journal
}

# This subshell keeps the recovery state for one database separate from the next restore.
restore_database() (
  local pg_container=$1 db_name=$2
  local suffix=${WORK##*.}
  local candidate_db=cw_restore_candidate_${db_name}_${suffix}
  local previous_db=cw_restore_previous_${db_name}_${suffix}
  local original_oid new_oid='' live_location current_journal candidate_journal ids companion
  local object_manifest object_plan='' journal membership_source=''
  local candidate_created=false journal_started=false
  local -a owners=() companions=()
  umask 077

  original_oid=$(database_oid "$pg_container" "$db_name") || return 1

  # Called by the EXIT trap.
  # shellcheck disable=SC2329
  finish_restore() {
    local status=$1 discarded_oid
    ((status != 0)) || return 0
    if [[ $journal_started == true && ( -e $RESTORE_JOURNAL || -L $RESTORE_JOURNAL ) ]]; then
      if ! recover_restore; then
        echo "$ENVIRONMENT: recovery of $db_name could not be verified; preserving the restore journal and databases" >&2
      fi
      return "$status"
    fi
    if [[ $candidate_created == true ]]; then
      if ! discarded_oid=$(database_oid "$pg_container" "$candidate_db"); then
        echo "$ENVIRONMENT: could not inspect candidate $candidate_db for cleanup" >&2
      elif [[ -n $new_oid && $discarded_oid == "$new_oid" ]]; then
        if ! psql_as "$pg_container" postgres postgres --set=name="$candidate_db" <<'SQL'
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

  psql_as "$pg_container" postgres postgres --set=candidate="$candidate_db" --set=migrator="${db_name}_migrator" <<'SQL' ||
CREATE DATABASE :"candidate" WITH OWNER :"migrator" ALLOW_CONNECTIONS false;
SQL
    return 1
  candidate_created=true
  new_oid=$(database_oid "$pg_container" "$candidate_db") || return 1
  [[ -n $new_oid ]] || return 1
  psql_as "$pg_container" postgres postgres --set=candidate="$candidate_db" <<'SQL' || return 1
BEGIN;
REVOKE ALL ON DATABASE :"candidate" FROM PUBLIC;
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS true;
COMMIT;
SQL

  if ! age --decrypt --identity "$IDENTITY" "$WORK/$db_name.dump.age" |
    docker exec -i "$pg_container" pg_restore --username="${db_name}_migrator" --no-password \
      --exit-on-error --no-owner --dbname="$candidate_db"; then
    echo "$ENVIRONMENT: the dump of $db_name could not be restored to the candidate; the live database was untouched" >&2
    return 1
  fi

  candidate_journal=$(migration_journal "$pg_container" "$candidate_db" "${db_name}_migrator") || return 1
  if [[ -n $original_oid ]]; then
    current_journal=$(migration_journal "$pg_container" "$db_name" "${db_name}_migrator") || return 1
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
  psql_as "$pg_container" postgres postgres --set=candidate="$candidate_db" --set=app="${db_name}_app" <<'SQL' ||
BEGIN;
ALTER DATABASE :"candidate" WITH ALLOW_CONNECTIONS false;
GRANT CONNECT ON DATABASE :"candidate" TO :"app";
COMMIT;
SQL
    return 1

  ids=$(containers_of "$db_name-service") || return 1
  if [[ -n $ids ]]; then mapfile -t owners <<<"$ids"; fi
  # The GitOps agent's allowlisted companions share their owner's application database.
  companion=$(companion_of "$db_name")
  if [[ -n $companion ]]; then
    ids=$(containers_of "$companion") || return 1
    if [[ -n $ids ]]; then mapfile -t companions <<<"$ids"; fi
  fi

  if ! verify_group postgres "$pg_container" ||
    ! verify_group "$db_name-service" "${owners[@]}" ||
    ! verify_group "$companion" "${companions[@]}"; then
    echo "$ENVIRONMENT: could not verify the workloads using $db_name; keeping the original database" >&2
    return 1
  fi

  if [[ $REBUILD_TASK_MEMBERSHIPS == true ]]; then
    membership_source=$(containers_of organization-service) || return 1
    if [[ ! $membership_source =~ ^[0-9a-f]{64}$ || ${#owners[@]} != 1 ]] ||
      ! verify_group organization-service "$membership_source"; then
      echo "$ENVIRONMENT: membership rebuild requires exactly one running Organization and Task container" >&2
      return 1
    fi
  fi

  journal=$(jq -en \
    --arg environment "$ENVIRONMENT" --arg postgres "$pg_container" --arg database "$db_name" --arg suffix "$suffix" \
    --arg original_oid "$original_oid" --arg candidate_oid "$new_oid" \
    --argjson owners "$(id_list_json "${owners[@]}")" --argjson companions "$(id_list_json "${companions[@]}")" \
    --argjson rebuild_memberships "$REBUILD_TASK_MEMBERSHIPS" \
    '{version: 1, phase: "pending", $environment, $postgres, $database, $suffix, $original_oid, $candidate_oid, $owners, $companions, $rebuild_memberships}') ||
    return 1
  journal_started=true
  if ! write_restore_journal "$journal" || ! validate_restore_journal; then
    echo "$ENVIRONMENT: could not persist a durable restore journal for $db_name" >&2
    return 1
  fi
  if ! stop_group 60 "${companions[@]}" || ! stop_group 30 "${owners[@]}"; then
    echo "$ENVIRONMENT: could not stop every user of $db_name; keeping the original database" >&2
    return 1
  fi
  if [[ -n $object_plan ]] && ! restore_storage_objects apply "$object_plan"; then
    echo "$ENVIRONMENT: Storage object recovery failed before cutover; keeping the original database" >&2
    return 1
  fi
  if [[ -n $membership_source ]] &&
    ! rebuild_task_memberships "$pg_container" "$candidate_db" "$suffix" "$membership_source" "${owners[0]}"; then
    echo "$ENVIRONMENT: could not rebuild Task memberships before cutover; keeping the original database" >&2
    return 1
  fi
  if ! switch_databases "$pg_container" "$db_name" "$candidate_db" "$previous_db" "$original_oid" "$new_oid" ||
    ! live_location=$(database_location "$pg_container" "$db_name") ||
    [[ $live_location != "$new_oid:open" ]]; then
    echo "$ENVIRONMENT: could not verify the cutover of $db_name" >&2
    return 1
  fi
  if ! start_group "${owners[@]}" || ! start_group "${companions[@]}"; then
    echo "$ENVIRONMENT: restored $db_name did not start with healthy services; recovering the prior state" >&2
    return 1
  fi
  if ! journal=$(jq -e '.phase = "committed"' "$RESTORE_JOURNAL") ||
    ! write_restore_journal "$journal" || ! remove_restore_journal; then
    echo "$ENVIRONMENT: could not complete the restore journal for $db_name" >&2
    return 1
  fi
  if [[ -n $original_oid ]]; then
    echo "$ENVIRONMENT: $db_name restored from $STAMP; prior database retained as $previous_db" >&2
  else
    echo "$ENVIRONMENT: $db_name restored from $STAMP" >&2
  fi
)

restore_environment() {
  local plain postgres database name bucket status=0 result
  local -a databases=("$@")
  (("${#databases[@]}")) || read -r -a databases <<<"$CADENWAY_BACKUP_DATABASES"
  for database in "${databases[@]}"; do
    valid_database_name "$database" || {
      echo "invalid service database name" >&2
      return 2
    }
  done

  WORK=$(mktemp -d /var/lib/cadenway-restore.XXXXXXXX) || return 1
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
    if ! download_verified_archive "$bucket" "$database"; then
      status=1
      continue
    fi
    result=0
    restore_database "$postgres" "$database" || result=$?
    rm -f -- "$WORK/$database.dump.age"
    if ((result >= 128)); then return "$result"; fi
    if [[ -e $RESTORE_JOURNAL || -L $RESTORE_JOURNAL ]]; then return 1; fi
    if ((result != 0)); then
      echo "$ENVIRONMENT: restoring $database failed" >&2
      status=1
    fi
  done
  return "$status"
}

main() {
  local mode=restore rebuild=false
  case ${1-} in
    --recover | --recover-under-lock)
      mode=$1
      shift
      [[ $# == 1 ]] || return 2
      ;;
    --rebuild-task-memberships)
      rebuild=true
      shift
      if (($# != 4)) || [[ $4 != task ]]; then
        echo "usage: cadenway-restore --rebuild-task-memberships <env> <timestamp> <identity file> task" >&2
        return 2
      fi
      ;;
    *)
      if (($# < 3)); then
        echo "usage: cadenway-restore <env> <timestamp> <identity file> [database...] | --recover <env>" >&2
        return 2
      fi
      ;;
  esac
  readonly REBUILD_TASK_MEMBERSHIPS=$rebuild
  readonly ENVIRONMENT=$1
  shift
  if [[ ! $ENVIRONMENT =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "invalid environment" >&2
    return 2
  fi
  readonly RESTORE_JOURNAL=$RESTORE_STATE/$ENVIRONMENT.json
  if [[ $mode == restore ]]; then
    readonly STAMP=$1 IDENTITY=$2
    shift 2
    if [[ ! $STAMP =~ ^[0-9]{8}T[0-9]{6}Z$ || ! -f $IDENTITY || ! -r $IDENTITY ]]; then
      echo "invalid timestamp or backup identity path" >&2
      return 2
    fi
  fi

  if [[ $mode == --recover-under-lock ]]; then
    # Accept only the inherited descriptor for the configured GitOps lock.
    [[ /proc/$$/fd/9 -ef $LOCK_FILE ]] && flock -xn 9 || return 1
  else
    exec 9>"$LOCK_FILE"
    flock -w 900 9 || {
      echo "the GitOps agent kept its lock for 15 minutes; try again" >&2
      return 1
    }
  fi
  if ! recover_restore; then
    echo "$ENVIRONMENT: outstanding restore could not be recovered; preserving $RESTORE_JOURNAL and databases" >&2
    return 1
  fi
  [[ $mode == restore ]] || return 0
  if [[ -e $AGENT_STATE/$ENVIRONMENT/rollout || -L $AGENT_STATE/$ENVIRONMENT/rollout ]]; then
    echo "$ENVIRONMENT: GitOps has an outstanding rollout; recover it before restoring" >&2
    return 1
  fi

  set -a
  # shellcheck source=/dev/null
  source /etc/cadenway/backup.env
  set +a
  export SOPS_AGE_KEY_FILE=/etc/cadenway/age.key
  restore_environment "$@"
}

main "$@"
