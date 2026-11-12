#!/usr/bin/env bash
# Nightly backup of the PostgreSQL databases of every environment on this host, to Object Storage.
#
# One `pg_dump --format=custom` per service database, streamed through age (encrypted to the backup
# recipient, whose private key never reaches a host) straight into the bucket: no plaintext dump
# touches the disk. Objects: <bucket>/<env>/<UTC timestamp>/<database>.dump.age.
#
# Old backups are deleted (retention) only after every database of the environment was saved: a
# failing night never costs the backups that still work. Any failure makes the unit fail and posts
# to the environment's ALERT_WEBHOOK_URL.
#
# The Object Storage credentials come from the environment's secrets.sops.env, decrypted in memory.
# Configuration: /etc/cadenway/backup.env (written by Ansible).
set -euo pipefail

# Plain KEY=value lines: CADENWAY_ENVIRONMENTS, CADENWAY_BACKUP_DATABASES, CADENWAY_BACKUP_RECIPIENT,
# CADENWAY_BACKUP_RETENTION_DAYS.
set -a
# shellcheck source=/dev/null
source /etc/cadenway/backup.env
set +a
export SOPS_AGE_KEY_FILE=/etc/cadenway/age.key

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
readonly STAMP

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

# Saves every database of one environment; returns 1 on the first problem, before any retention.
backup_environment() {
  local env=$1 postgres database plain bucket name object failures=0
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
    object="backup:$bucket/$env/$STAMP/$database.dump.age"
    if docker exec "$postgres" pg_dump --username=postgres --format=custom "$database" |
      age --encrypt --recipient "$CADENWAY_BACKUP_RECIPIENT" |
      rclone rcat "$object"; then
      echo "$env: $database saved to $env/$STAMP" >&2
    else
      echo "$env: $database FAILED; removing the partial object" >&2
      rclone deletefile "$object" 2>/dev/null || true
      failures=$((failures + 1))
    fi
  done
  ((failures == 0)) || return 1

  rclone delete --min-age "${CADENWAY_BACKUP_RETENTION_DAYS}d" "backup:$bucket/$env/" || return 1
  rclone rmdirs --leave-root "backup:$bucket/$env/" || true
}

main() {
  local env status=0
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
