#!/bin/sh
# Creates the JetStream streams of an environment and keeps them as declared below.
#
# The backends cannot do it: their NATS users may publish and consume, not create a stream
# (nats/nats-server.conf). This script is the only owner of the streams. It runs in the
# `nats-streams` container of compose/infra.yaml, with the `admin` user, for as long as the
# environment runs: it applies the declarations at start, then checks every minute that the
# streams still exist and creates them again when the broker lost its data.
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
# Durables of cadenway-realtime-gateway that invalidate the authorization of a socket, as its
# relayInvalidationHandlers name them (src/modules/relays/presentation/messaging/handlers/relay/).
# The gateway admits no socket unless REALTIME_AUTHORIZATION_ADVISORIES captures exactly their
# terminal advisories: a handler added, renamed or removed there changes this list, like its grant
# in nats-server.conf, before the release that changes it.
readonly REALTIME_INVALIDATION_DURABLES='relay-session-revoked relay-session-organization-changed
  relay-member-removed relay-member-role-changed relay-space-updated relay-space-access-changed
  relay-space-access-republished relay-space-deleted relay-list-access-changed relay-list-deleted
  relay-task-trashed relay-task-purged relay-task-updated'

# searchSourceHandlerNames in cadenway-search-service's search-source-events.handler.ts. Changes
# require the same coordinated cutover as the consumer grants and the realtime latch subjects.
readonly SEARCH_REBUILD_DURABLES='index-task-created-v1 index-task-updated-v1 index-task-archived-v1
  index-task-unarchived-v1 index-task-trashed-v1 index-task-restored-v1
  index-task-purged-v1 index-task-watcher-changed-v1 index-comment-created-v1
  index-comment-updated-v1 index-comment-deleted-v1 index-list-created-v1
  index-list-updated-v1 index-list-archived-v1 index-list-unarchived-v1
  index-list-deleted-v1 index-list-restored-v1 index-list-access-changed-v1
  index-space-created-v1 index-space-updated-v1 index-space-deleted-v1
  index-space-restored-v1 index-space-access-changed-v1 index-space-access-republished-v1
  index-doc-created-v1 index-doc-updated-v1 index-doc-deleted-v1 index-file-uploaded-v1
  index-file-deleted-v1'
# usageObservationHandlerNames in cadenway-billing-service's usage-observation-events.handler.ts.
# Changes require the same coordinated cutover as the consumer grants and realtime latch subjects.
readonly BILLING_REBUILD_DURABLES='register-organization record-member-joined
  record-member-role-changed record-member-removed record-file-uploaded record-file-deleted'

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

# Creates or updates the advisory latch of a service: it keeps the last advisory the server
# publishes when one of the listed durables gives a message up (after its last delivery or on a
# terminate), with no age limit, until an operator purges it (docs/messaging.md#rebuild-advisories,
# docs/messaging.md#realtime-authorization-advisories). @cadenway/nest-messaging requires exactly
# this configuration (file storage, limits retention, old messages discarded, one message, no other
# limit) and an empty stream before the service trusts its consumers; an edit sets every one of
# those settings that can change again.
#
# The latch starts empty only while EVENTS has no consumer of the service. A latch missing once the
# service consumes (a stream removed, not recovered by the broker, or provisioned after the service
# started) may have missed an advisory: it is created closed, holding a marker an operator purges
# after reconciling. When the marker cannot be stored, the stream is removed again so that the next
# pass retries the whole step instead of leaving an empty latch.
# Arguments: stream, service (durable prefix), handlers, description, marker type, marker reason.
# Returns non-zero when a step fails.
ensure_latch() {
  latch=$1
  service=$2
  durables=$3
  description=$4
  marker_type=$5
  marker_reason=$6
  subjects=''
  for handler in $durables; do
    for kind in MAX_DELIVERIES MSG_TERMINATED; do
      subject="\$JS.EVENT.ADVISORY.CONSUMER.$kind.EVENTS.${service}__$handler"
      subjects="${subjects:+$subjects,}$subject"
    done
  done
  if nats stream info "$latch" >/dev/null 2>&1; then
    nats stream edit "$latch" --force \
      --subjects "$subjects" --description "$description" --discard old \
      --max-age 0 --max-bytes=-1 --max-msgs=1 --max-msgs-per-subject=-1 \
      --max-msg-size=-1 >/dev/null
    return
  fi
  consumers=$(nats consumer ls EVENTS --names) || return 1
  nats stream add "$latch" --defaults \
    --subjects "$subjects" --description "$description" \
    --storage file --retention limits --discard old --replicas 1 \
    --max-age 0 --max-bytes=-1 --max-msgs=1 --max-msgs-per-subject=-1 \
    --max-msg-size=-1 >/dev/null || return 1
  printf '%s\n' "$consumers" | grep -q "^${service}__" || return 0
  marker="\$JS.EVENT.ADVISORY.CONSUMER.MSG_TERMINATED.EVENTS.${service}__${durables%% *}"
  if nats request "$marker" \
    "{\"type\":\"$marker_type\",\"reason\":\"$marker_reason\"}" 2>&1 |
    grep -Fq "\"stream\":\"$latch\""; then
    echo "nats-streams: $latch was lost and is created again closed." >&2
    return 0
  fi
  nats stream rm "$latch" --force >/dev/null 2>&1
  return 1
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
    ensure_latch REALTIME_AUTHORIZATION_ADVISORIES realtime-gateway \
      "$REALTIME_INVALIDATION_DURABLES" \
      'Last authorization invalidation realtime-gateway gave up on; purged by an operator.' \
      'io.cadenway.realtime.latch-recreated' \
      'The latch was lost while the realtime gateway consumed; reconcile, then purge.' &&
    ensure_latch SEARCH_REBUILD_ADVISORIES search-service "$SEARCH_REBUILD_DURABLES" \
      'Last search rebuild source event given up; purged by an operator.' \
      'io.cadenway.search.latch-recreated' \
      'The latch was lost while search-service consumed; reconcile, then purge.' &&
    ensure_latch BILLING_REBUILD_ADVISORIES billing-service "$BILLING_REBUILD_DURABLES" \
      'Last billing usage observation given up; purged by an operator.' \
      'io.cadenway.billing.latch-recreated' \
      'The latch was lost while billing-service consumed; reconcile, then purge.'
}

streams_exist() {
  nats stream info EVENTS >/dev/null 2>&1 &&
    nats stream info EVENTS_RESTRICTED >/dev/null 2>&1 &&
    nats stream info EVENTS_DLQ >/dev/null 2>&1 &&
    nats stream info REALTIME_AUTHORIZATION_ADVISORIES >/dev/null 2>&1 &&
    nats stream info SEARCH_REBUILD_ADVISORIES >/dev/null 2>&1 &&
    nats stream info BILLING_REBUILD_ADVISORIES >/dev/null 2>&1
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
    echo 'nats-streams: the streams and advisory latches are in place.'
    : >"$READY"
    pause "$CHECK_INTERVAL"
  else
    rm -f "$READY"
    echo 'nats-streams: the streams are not in place yet; trying again.' >&2
    pause "$RETRY_INTERVAL"
  fi
done
