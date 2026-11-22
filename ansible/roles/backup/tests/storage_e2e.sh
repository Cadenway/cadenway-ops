#!/usr/bin/env bash
# Sourced by e2e.sh after validating the local image and the isolated runner.

readonly NATS='nats:2.15.2-alpine@sha256:afae2fdbe2e326c65e1246cb83b9d05d319188734f3bd577ac8072daae78a10f'
readonly NATS_BOX='natsio/nats-box:0.20.2-nonroot@sha256:d00bffed51ea1a29e58852698bde37020d306af55585882f88dbcf09dd86f5fe'
readonly STORAGE_FIXTURE_NETWORK="container:$HOSTNAME"

storage_api() {
  docker run --pull never --rm -i --network "$STORAGE_FIXTURE_NETWORK" \
    --entrypoint node -e CW_FIXTURE_SIGNER "$CADENWAY_E2E_STORAGE_IMAGE" \
    --input-type=module - "$@" </backup/tests/storage_api.mjs
}

elected_attachment() {
  sql -d storage --set="id=$1" <<'SQL'
SELECT elected_object_key FROM attachments WHERE id = :'id' AND status = 'ready' AND scan_status = 'verified';
SQL
}

wait_for_attachment_cleanup() {
  local key=$1 cleaned
  # The real service's cleanup sweep runs once a minute. Capture S3 history only
  # after it has finished so the fixture cannot race the application's delete marker.
  for _ in {1..120}; do
    cleaned=$(sql -d storage --set="key=$key" <<'SQL'
SELECT status = 'cleaned' FROM attachment_candidates WHERE object_key = :'key';
SQL
    ) || return 1
    if [[ $cleaned == t ]]; then return 0; fi
    sleep 1
  done
  echo 'Storage did not record the elected attachment cleanup.' >&2
  return 1
}

echo '=== Storage API 1. start the real service and apply its migrations'
start_postgres "$STORAGE_FIXTURE_NETWORK"
start_files_s3
storage_fixture create-bucket
docker run --pull never -d --name "$BROKER" --network "$STORAGE_FIXTURE_NETWORK" \
  "$NATS" --jetstream --store_dir /data --addr 127.0.0.1 --http_port 8222 >/dev/null
poll curl --fail --silent --max-time 2 -o /dev/null http://127.0.0.1:8222/healthz
docker run --pull never --rm --network "$STORAGE_FIXTURE_NETWORK" --entrypoint nats "$NATS_BOX" \
  --server nats://127.0.0.1:4222 stream add EVENTS --defaults --subjects 'evt.>' \
  --storage file --retention limits --replicas 1 >/dev/null
docker run --pull never --rm --network "$STORAGE_FIXTURE_NETWORK" --entrypoint nats "$NATS_BOX" \
  --server nats://127.0.0.1:4222 stream add EVENTS_DLQ --defaults --subjects 'dlq.>' \
  --storage file --retention limits --replicas 1 >/dev/null

# Provision the DB roles. The service's migrator owns the schema and the business data is entered through HTTP.
sql <<'SQL'
CREATE ROLE storage_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE storage_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE storage OWNER storage_migrator;
REVOKE ALL ON DATABASE storage FROM PUBLIC;
GRANT CONNECT ON DATABASE storage TO storage_app;
SQL
sql -d storage <<'SQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO storage_app;
ALTER DEFAULT PRIVILEGES FOR ROLE storage_migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO storage_app;
ALTER DEFAULT PRIVILEGES FOR ROLE storage_migrator IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO storage_app;
SQL
docker run --pull never --rm --network "$STORAGE_FIXTURE_NETWORK" --entrypoint node \
  -e MIGRATION_DATABASE_URL=postgres://storage_migrator@127.0.0.1:5432/storage \
  "$CADENWAY_E2E_STORAGE_IMAGE" dist/migrate.js

CW_FIXTURE_SIGNER=$(storage_api keypair)
export CW_FIXTURE_SIGNER
trusted_public_key=$(storage_api public-key)
receipt_keyring=$(storage_api receipt-keyring)
docker run --pull never -d --name "$STORAGE" --network "$STORAGE_FIXTURE_NETWORK" \
  --label "com.docker.compose.project=$PROJECT" --label com.docker.compose.service=storage-service \
  --health-interval=1s --health-start-period=3s --health-start-interval=1s --health-retries=25 \
  -e NODE_ENV=production -e PORT=3015 -e LOG_LEVEL=warn -e LOG_PRETTY=false \
  -e DATABASE_URL=postgres://storage_app@127.0.0.1:5432/storage -e NATS_URL=nats://127.0.0.1:4222 \
  -e INTERNAL_TOKEN_AUDIENCE=storage-service -e "INTERNAL_TOKEN_TRUSTED_ISSUERS=$trusted_public_key" \
  -e "S3_ENDPOINT=$STORAGE_S3_ENDPOINT" -e "S3_PUBLIC_ENDPOINT=$STORAGE_S3_ENDPOINT" \
  -e "S3_REGION=$STORAGE_S3_REGION" -e "S3_BUCKET=$STORAGE_S3_BUCKET" -e S3_FORCE_PATH_STYLE=true \
  -e S3_ERASE_TRANSIENT_VERSIONS=true \
  -e "S3_ACCESS_KEY_ID=$STORAGE_RESTORE_S3_ACCESS_KEY_ID" \
  -e "S3_SECRET_ACCESS_KEY=$STORAGE_RESTORE_S3_SECRET_ACCESS_KEY" \
  -e STORAGE_UPLOAD_TRANSFER_URL=http://127.0.0.1:3016/internal/v1/upload-transfers \
  -e "STORAGE_UPLOAD_RECEIPT_KEYS=$receipt_keyring" "$CADENWAY_E2E_STORAGE_IMAGE" >/dev/null
unset receipt_keyring
if ! poll healthy "$STORAGE"; then
  echo 'Storage did not become ready with the fixture configuration.' >&2
  exit 1
fi
for container in "$HOSTNAME" "$SERVER" "$BROKER" "$FILES_S3" "$STORAGE"; do
  [[ $(docker inspect --format '{{ len .HostConfig.PortBindings }}' "$container") == 0 ]]
done
echo 'PASS real Storage is healthy with no published ports'

echo '=== Storage API 2. verify one-shot uploads and back up the Storage database'
avatar_id=$(sql -c 'SELECT uuidv7()')
state=$(storage_api upload "$avatar_id")
avatar_staging_key=$(sql -d storage --set="id=$(jq -er .avatarId <<<"$state")" <<'SQL'
SELECT 'profile-media/staging/' || object_id FROM profile_media_objects
WHERE upload_id = :'id' AND role = 'staging';
SQL
)
[[ $avatar_staging_key == profile-media/staging/* ]]
storage_fixture history "$avatar_staging_key" | jq -e \
  'map(select(.[1] == "Versions")) | length == 1' >/dev/null
attachment_key=$(elected_attachment "$(jq -er .attachmentId <<<"$state")")
avatar_key=$(sql -d storage --set="id=$(jq -er .avatarId <<<"$state")" <<'SQL'
SELECT 'profile-media/candidate/' || candidate_id FROM profile_media_uploads WHERE upload_id = :'id' AND status = 'prepared';
SQL
)
[[ $attachment_key == org/*/* && $avatar_key == profile-media/candidate/* ]]
avatar_pin_history=$(storage_fixture history "attachment-restore-pins/$avatar_key")
jq -e 'any(.[]; .[1] == "Versions")' <<<"$avatar_pin_history" >/dev/null
storage_api verify "$state"
echo 'PASS attachment, intake and avatar each accepted one transfer; concurrent avatar submissions created one S3 version'
prepare_backups storage
cadenway-backup
stamp=$(storage_stamp)
[[ $stamp =~ ^[0-9]{8}T[0-9]{6}Z$ && -s $(backup_archive "$stamp" storage) ]]
echo 'PASS encrypted backup and signed manifest exist before the files were hidden'

echo '=== Storage API 3. upload another file after the dump and delete the originals'
late=$(storage_api upload-later)
late_key=$(elected_attachment "$(jq -er .attachmentId <<<"$late")")
late_sha=$(jq -er .attachmentSha256 <<<"$late")
[[ $late_key == org/*/* && $(storage_fixture digest "$late_key") == "$late_sha" ]]
late_history=$(storage_fixture history "$late_key")
storage_api delete-attachment "$state"
wait_for_attachment_cleanup "$attachment_key"
storage_fixture hide "$attachment_key" "$avatar_key"
storage_api missing-avatar "$state"
history=$(storage_fixture history "$attachment_key" "$avatar_key")

echo '=== Storage API 4. restore PostgreSQL and download the restored bytes'
original_database=$(storage_db_id)
original_start=$(started_at "$STORAGE")
storage_restore "$stamp"
[[ $(storage_db_id) != "$original_database" && $(started_at "$STORAGE") != "$original_start" ]]
poll healthy "$STORAGE"
echo 'PASS PostgreSQL switched databases and the real Storage process restarted healthy'
storage_fixture verify-recovered-versions "$attachment_key" "$avatar_key" <<<"$history"
storage_api verify "$state"
storage_api later-metadata-rolled-back "$late"
[[ $(storage_fixture history "$late_key") == "$late_history" && $(storage_fixture digest "$late_key") == "$late_sha" ]]
echo 'PASS restore preserved the post-dump S3 object bytes and version history'

echo '=== Storage API 5. replay the restore'
recovered_history=$(storage_fixture history "$attachment_key" "$avatar_key")
storage_restore "$stamp"
[[ $(storage_fixture history "$attachment_key" "$avatar_key") == "$recovered_history" ]]
storage_api verify "$state"
[[ $(storage_fixture history "$late_key") == "$late_history" && $(storage_fixture digest "$late_key") == "$late_sha" ]]
[[ -z $(candidate_databases) && -z $(temporary_archives) ]]
echo 'PASS replay preserved both HTTP downloads, the post-dump object and all their versions'
echo 'PASS replay removed temporary restore data'

echo '=== Storage API 6. transient avatar versions are collected'
for _ in {1..60}; do
  staging_history=$(storage_fixture history "$avatar_staging_key")
  if [[ $staging_history == '[]' ]]; then break; fi
  sleep 3
done
if [[ $staging_history != '[]' ]]; then
  echo 'Storage did not collect the expired avatar staging history.' >&2
  exit 1
fi
[[ $(storage_fixture history "$attachment_key" "$avatar_key") == "$recovered_history" ]]
[[ $(storage_fixture history "attachment-restore-pins/$avatar_key") == "$avatar_pin_history" ]]
storage_api verify "$state"
echo 'PASS the sweeper removed all versions of staging while restored downloads stayed readable'
