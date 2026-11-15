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
# is applied when the container starts: change ENSURE_STREAMS_SHA256 in infra.yaml with this file,
# so that every environment restarts it. The storage type of an existing stream cannot be changed.
set -eu

readonly READY=/tmp/streams-ready
readonly CHECK_INTERVAL=60
readonly RETRY_INTERVAL=5

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
# rows; dead letters wait longer for an operator.
ensure_streams() {
  ensure_stream EVENTS 'evt.>' 7d 1GiB \
    'Every Cadenway event.' &&
    ensure_stream EVENTS_RESTRICTED 'restricted.>' 7d 64MiB \
      'Identity events carrying a single-use code or link; read by notification-service only.' &&
    ensure_stream EVENTS_DLQ 'dlq.>' 30d 256MiB \
      'Messages a consumer gave up on, copied by the dead-letter worker.'
}

streams_exist() {
  nats stream info EVENTS >/dev/null 2>&1 &&
    nats stream info EVENTS_RESTRICTED >/dev/null 2>&1 &&
    nats stream info EVENTS_DLQ >/dev/null 2>&1
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
    echo 'nats-streams: EVENTS, EVENTS_RESTRICTED and EVENTS_DLQ are in place.'
    : >"$READY"
    pause "$CHECK_INTERVAL"
  else
    rm -f "$READY"
    echo 'nats-streams: the streams are not in place yet; trying again.' >&2
    pause "$RETRY_INTERVAL"
  fi
done
