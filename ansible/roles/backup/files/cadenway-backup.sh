#!/usr/bin/env bash
# Nightly backup of the PostgreSQL databases of every environment on this host, to Object Storage.
#
# One `pg_dump --format=custom` per service database, streamed through age before staging the
# ciphertext. Each snapshot has a content-addressed object and a signed manifest published last.
#
# Object Storage manages retention independently of this host. Any backup failure makes the unit
# fail and posts to the environment's ALERT_WEBHOOK_URL.
#
# The Object Storage credentials come from the environment's secrets.sops.env, decrypted in memory.
# Configuration: /etc/cadenway/backup.env (written by Ansible).
set -euo pipefail

# Plain KEY=value lines: CADENWAY_ENVIRONMENTS, CADENWAY_BACKUP_DATABASES, CADENWAY_BACKUP_RECIPIENT.
set -a
# shellcheck source=/dev/null
source /etc/cadenway/backup.env
set +a
export SOPS_AGE_KEY_FILE=/etc/cadenway/age.key

readonly SIGNING_KEY=/etc/cadenway/backup-signing.key
readonly ALLOWED_SIGNERS=/etc/cadenway/backup-allowed-signers
readonly SIGNING_NAMESPACE=cadenway-backup-manifest-v1

secret() { sed -n "s/^$2=//p" <<<"$1" | tail -n 1; }

# Posts a one-line message to the webhook (Slack-compatible), the URL never in curl's arguments.
notify() {
  local url=$1 message=$2
  echo "$message" >&2
  [[ -n $url ]] || return 0
  jq -cn --arg text "$message" '{text: $text}' |
    curl -fsS --max-time 10 -H 'Content-Type: application/json' --data @- \
      --config <(printf 'url = "%s"\n' "$url") >/dev/null || true
}

# Publish the ciphertext first. A missing manifest leaves the generation ineligible for restore.
publish_database() (
  local postgres=$1 env=$2 bucket=$3 database=$4 work digest size object prefix
  umask 077
  work=$(mktemp -d /var/lib/cadenway-backup.XXXXXXXX) || return 1
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! docker exec "$postgres" pg_dump --username=postgres --format=custom "$database" |
    age --encrypt --recipient "$CADENWAY_BACKUP_RECIPIENT" >"$work/archive"; then
    return 1
  fi

  digest=$(sha256sum <"$work/archive") || return 1
  digest=${digest%% *}
  size=$(wc -c <"$work/archive") || return 1
  prefix="$env/$STAMP/$database"
  object="$prefix-$digest.dump.age"

  jq -cn --arg env "$env" --arg stamp "$STAMP" --arg database "$database" \
    --arg bucket "$bucket" --arg object "$object" --arg sha256 "$digest" --argjson size "$size" \
    '{version: 1, $env, $stamp, $database, $bucket, $object, $sha256, $size}' >"$work/manifest" ||
    return 1
  ssh-keygen -Y sign -f "$SIGNING_KEY" -n "$SIGNING_NAMESPACE" "$work/manifest" >/dev/null ||
    return 1
  # A configuration or rotation mistake must not publish a backup the restore host cannot verify.
  ssh-keygen -Y verify -f "$ALLOWED_SIGNERS" -I cadenway-backup -n "$SIGNING_NAMESPACE" \
    -s "$work/manifest.sig" <"$work/manifest" >/dev/null || return 1
  jq -cn --rawfile manifest "$work/manifest" --rawfile signature "$work/manifest.sig" \
    '{$manifest, $signature}' >"$work/signed-manifest" || return 1

  rclone copyto --immutable --checksum --s3-no-check-bucket "$work/archive" "backup:$bucket/$object" &&
    rclone copyto --immutable --checksum --s3-no-check-bucket \
      "$work/signed-manifest" "backup:$bucket/$prefix.manifest.json"
)

# Save every database of one environment and keep trying after an individual failure.
backup_environment() {
  local env=$1 postgres database plain bucket name failures=0
  postgres=$(docker ps -q --filter "label=com.docker.compose.project=cadenway-$env" \
    --filter label=com.docker.compose.service=postgres)
  if [[ -z $postgres ]]; then
    echo "$env: PostgreSQL is not running" >&2
    return 1
  fi
  plain=$(sops --decrypt --input-type dotenv --output-type dotenv \
    "/opt/cadenway/envs/$env/environments/$env/secrets.sops.env") || return 1
  ALERT_URL=$(secret "$plain" ALERT_WEBHOOK_URL)

  # rclone reads the remote from environment variables only (no config file on disk).
  export RCLONE_CONFIG_BACKUP_TYPE=s3 RCLONE_CONFIG_BACKUP_PROVIDER=Other
  for name in ENDPOINT REGION ACCESS_KEY_ID SECRET_ACCESS_KEY; do
    [[ -n $(secret "$plain" "BACKUP_S3_$name") ]] || {
      echo "$env: BACKUP_S3_$name is missing from the secrets" >&2
      return 1
    }
    export "RCLONE_CONFIG_BACKUP_$name=$(secret "$plain" "BACKUP_S3_$name")"
  done
  bucket=$(secret "$plain" BACKUP_S3_BUCKET)
  [[ -n $bucket ]] || {
    echo "$env: BACKUP_S3_BUCKET is missing from the secrets" >&2
    return 1
  }

  for database in $CADENWAY_BACKUP_DATABASES; do
    if publish_database "$postgres" "$env" "$bucket" "$database"; then
      echo "$env: $database saved to $env/$STAMP" >&2
    else
      echo "$env: $database FAILED" >&2
      failures=$((failures + 1))
    fi
  done
  ((failures == 0))
}

main() {
  local env status=0
  # Serialize manual and timer starts before choosing the snapshot timestamp.
  exec 9>/run/lock/cadenway-backup.lock
  flock -n 9 || {
    echo "a backup is already running" >&2
    return 1
  }
  STAMP=$(date -u +%Y%m%dT%H%M%SZ)
  readonly STAMP
  for env in $CADENWAY_ENVIRONMENTS; do
    ALERT_URL=''
    if ! backup_environment "$env"; then
      status=1
      notify "$ALERT_URL" "cadenway $env: the nightly backup FAILED on $(hostname); older backups were kept"
    fi
  done
  return "$status"
}

main "$@"
