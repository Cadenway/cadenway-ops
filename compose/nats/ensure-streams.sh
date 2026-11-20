#!/bin/sh
# Creates the JetStream streams of an environment and keeps them as declared below.
#
# The backends cannot do it: their NATS users may publish and consume, not create a stream
# (nats/nats-server.conf). This script is the only owner of the streams. It runs in the
# `nats-streams` container of compose/infra.yaml, with the `admin` user, for as long as the
# environment runs: it applies the declarations at start, then checks every minute that the
# event streams still exist. A previously provisioned authorization latch must be recovered
# explicitly if the broker loses or replaces it.
#
# Environment: NATS_URL, NATS_USER, NATS_PASSWORD (read by the `nats` command line itself).
# The file /tmp/streams-ready exists while every stream is in place: the health check of the
# container reads it, so the services of the local stack and the GitOps agent wait for the streams.
# Never exits on its own; a failed pass is tried again after a few seconds.
#
# Sizes are starting values: adjust them once the disk of the VPS is known. A value changed here
# is applied when the container starts, to a stream that exists as to a new one: change
# ENSURE_STREAMS_SHA256 in infra.yaml with this file, so that every environment restarts it. The
# storage type and the retention of an existing stream cannot be changed; a lower maximum age drops
# the messages older than it at once.
set -eu

readonly READY=/tmp/streams-ready
readonly CHECK_INTERVAL=60
readonly RETRY_INTERVAL=5
readonly LATCH_IDENTITY=/home/nats/realtime-authorization-advisories.created

# The exact invalidation durables that can revoke a socket's authority. Status and comment
# notifications do not change authority and do not open this latch.
readonly AUTHORIZATION_HANDLERS='relay-session-revoked relay-session-organization-changed relay-member-removed relay-member-role-changed relay-space-updated relay-space-access-changed relay-space-access-republished relay-space-deleted relay-list-access-changed relay-list-deleted relay-task-trashed relay-task-purged relay-task-updated'

# Verifies the broker still has the same provisioned latch, without changing it.
realtime_latch_identity_matches() {
  [ -s "$LATCH_IDENTITY" ] || return 1
  expected=$(cat "$LATCH_IDENTITY") || return 1
  observed=$(nats stream info REALTIME_AUTHORIZATION_ADVISORIES --json 2>/dev/null |
    jq -er '.created | select(type == "string" and length > 0)') || return 1
  [ "$observed" = "$expected" ]
}

# A retained advisory is a persistent latch. Editing a stream never clears its message.
ensure_realtime_authorization_advisories() {
  subjects=''
  for handler in $AUTHORIZATION_HANDLERS; do
    for advisory in MAX_DELIVERIES MSG_TERMINATED; do
      subject="\$JS.EVENT.ADVISORY.CONSUMER.$advisory.EVENTS.realtime-gateway__$handler"
      subjects="${subjects:+$subjects,}$subject"
    done
  done
  name=REALTIME_AUTHORIZATION_ADVISORIES
  if [ -e "$LATCH_IDENTITY" ]; then
    if ! realtime_latch_identity_matches; then
      echo 'nats-streams: unable to verify the provisioned Realtime authorization latch; check NATS and its recovery procedure.' >&2
      return 1
    fi
  else
    if ! nats stream info "$name" >/dev/null 2>&1; then
      nats stream add "$name" --defaults --subjects "$subjects" \
        --description 'Persistent latch for failed Realtime authorization invalidations.' \
        --storage file --retention limits --discard old --replicas 1 \
        --max-age 0s --max-bytes=-1 --max-msgs=1 --max-msgs-per-subject=-1 \
        --max-msg-size=-1 >/dev/null || return 1
    fi
    created=$(nats stream info "$name" --json |
      jq -er '.created | select(type == "string" and length > 0)') || return 1
    printf '%s\n' "$created" >"$LATCH_IDENTITY.tmp" || return 1
    mv "$LATCH_IDENTITY.tmp" "$LATCH_IDENTITY" || return 1
  fi
  realtime_latch_identity_matches || return 1
  nats stream edit "$name" --force --subjects "$subjects" \
    --max-age 0s --max-bytes=-1 --max-msgs=1 --max-msgs-per-subject=-1 \
    --max-msg-size=-1 --discard old >/dev/null || return 1
  # The CLI cannot disable per-message TTL once enabled. Do not report readiness if an
  # operator-configured stream would let a retained advisory expire.
  nats stream info "$name" --json |
    jq -e '.config | (.allow_msg_ttl // false) == false' >/dev/null &&
    realtime_latch_identity_matches
}

# Creates a stream, or updates it when it exists.
# Arguments: name, subjects, maximum age, maximum size in bytes, description.
# Returns the status of the `nats` command.
ensure_stream() {
  name=$1
  subjects=$2
  max_age=$3
  max_bytes=$4
  description=$5

  if nats stream info "$name" >/dev/null 2>&1; then
    nats stream edit "$name" --force \
      --subjects "$subjects" --description "$description" \
      --max-age "$max_age" --max-bytes "$max_bytes" --dupe-window 2m >/dev/null
  else
    nats stream add "$name" --defaults \
      --subjects "$subjects" --description "$description" \
      --storage file --retention limits --discard old --replicas 1 \
      --max-age "$max_age" --max-bytes "$max_bytes" --dupe-window 2m \
      --max-msgs=-1 --max-msgs-per-subject=-1 --max-msg-size=-1 >/dev/null
  fi
}

# One pass over the declarations. The two-minute duplicate window is the one the publishers rely
# on (`Nats-Msg-Id` is the event id). Seven days matches the time a service keeps its sent outbox
# rows. A restricted event carries a single-use code valid ten minutes, or a link that expires as
# soon: one hour delivers it through a short outage of notification-service, and none stays
# readable in the stream past its use. Dead letters wait longer for an operator.
ensure_streams() {
  ensure_stream EVENTS 'evt.>' 7d 1GiB \
    'Every Cadenway event.' &&
    ensure_stream EVENTS_RESTRICTED 'restricted.>' 1h 64MiB \
      'Identity events carrying a single-use code or link; read by notification-service only.' &&
    ensure_stream EVENTS_DLQ 'dlq.>' 30d 256MiB \
      'Messages a consumer gave up on, copied by the dead-letter worker.' &&
    ensure_realtime_authorization_advisories
}

streams_exist() {
  nats stream info EVENTS >/dev/null 2>&1 &&
    nats stream info EVENTS_RESTRICTED >/dev/null 2>&1 &&
    nats stream info EVENTS_DLQ >/dev/null 2>&1 &&
    realtime_latch_identity_matches
}

# `sleep` runs in the background so the shell, as process 1, answers the stop signal at once.
trap 'exit 0' TERM INT
pause() {
  sleep "$1" &
  wait $!
}

rm -f "$READY"
while :; do
  if [ -e "$READY" ] && streams_exist; then
    pause "$CHECK_INTERVAL"
  elif ensure_streams; then
    echo 'nats-streams: event streams and the Realtime authorization advisory latch are in place.'
    : >"$READY"
    pause "$CHECK_INTERVAL"
  else
    rm -f "$READY"
    echo 'nats-streams: the streams are not in place yet; trying again.' >&2
    pause "$RETRY_INTERVAL"
  fi
done
