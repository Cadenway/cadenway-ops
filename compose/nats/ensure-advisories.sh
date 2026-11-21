#!/bin/sh
# Owns the local observation stream and cursor. The reader cannot create or reset either.
set -eu

readonly STREAM=EVENTS_ADVISORIES
readonly DURABLE=notification-dead-letter-advisories-v1
# These are literal JetStream subjects.
# shellcheck disable=SC2016
readonly SUBJECTS='[
  "$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS.>",
  "$JS.EVENT.ADVISORY.CONSUMER.MSG_TERMINATED.EVENTS.>",
  "$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS_RESTRICTED.>",
  "$JS.EVENT.ADVISORY.CONSUMER.MSG_TERMINATED.EVENTS_RESTRICTED.>"
]'
readonly STATE=/home/nats/advisories.created
readonly READY=/tmp/advisories-ready

provision() {
  if [ -e "$STATE" ]; then return 0; fi

  if ! nats --timeout 2s stream info "$STREAM" >/dev/null 2>&1; then
    subjects=$(printf '%s\n' "$SUBJECTS" | jq -er 'join(",")') || return 1
    nats --timeout 2s stream add "$STREAM" --defaults --subjects "$subjects" \
      --storage file --retention work --discard new --replicas 1 \
      --max-age 7d --max-bytes 64MiB --max-msgs 100000 >/dev/null || return 1
  fi

  if ! nats --timeout 2s consumer info "$STREAM" "$DURABLE" >/dev/null 2>&1; then
    nats --timeout 2s consumer add "$STREAM" "$DURABLE" --defaults --pull --ack explicit \
      --deliver all --replay instant --wait 30s --max-deliver=-1 --max-pending 16 \
      --max-waiting 32 --max-pull-batch 16 --max-pull-expire 30s >/dev/null || return 1
  fi
}

# Use the creation timestamps to detect a lost disk or reset cursor. Recreating either would
# restore readiness while hiding the gap. Creating this state file is part of initial provisioning.
capture_identity() {
  stream=$(nats --timeout 2s stream info "$STREAM" --json) || return 1
  stream_created=$(printf '%s\n' "$stream" | jq -er --argjson subjects "$SUBJECTS" '
    select(.config.storage == "file" and .config.retention == "workqueue" and
      .config.discard == "new" and (.config.subjects | sort) == ($subjects | sort) and
      .config.max_age == 604800000000000 and .config.max_bytes == 67108864 and
      .config.max_msgs == 100000 and .state.bytes < 60397978 and .state.messages < 90000)
    | .created | select(type == "string" and length > 0)
  ') || return 1
  consumer=$(nats --timeout 2s consumer info "$STREAM" "$DURABLE" --json) || return 1
  consumer_created=$(printf '%s\n' "$consumer" | jq -er '
    select(.config.ack_policy == "explicit" and .config.deliver_policy == "all" and
      (.config.deliver_subject // "") == "" and (.config.filter_subject // "") == "" and
      (.config.filter_subjects // [] | length) == 0 and
      .config.ack_wait == 30000000000 and .config.max_deliver == -1 and
      .config.max_ack_pending == 16 and .config.max_waiting == 32 and
      .config.max_batch == 16 and .config.max_expires == 30000000000)
    | .created | select(type == "string" and length > 0)
  ') || return 1
  printf '%s\n%s\n' "$stream_created" "$consumer_created"
}

capture_ready() {
  provision || return 1
  identity=$(capture_identity) || return 1
  if [ -e "$STATE" ]; then
    [ "$identity" = "$(cat "$STATE")" ] || return 1
  else
    printf '%s\n' "$identity" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE" || return 1
  fi
  # A connected leaf can serve its own API before the hub has registered its capture subjects.
  leaf=$(wget -qO- -T 2 'http://nats:8222/leafz?subs=1') || return 1
  printf '%s\n' "$leaf" | jq -e --argjson subjects "$SUBJECTS" '
    .leafnodes == 1 and (($subjects - (.leafs[0].subscriptions_list // [])) | length) == 0
  ' >/dev/null
}

trap 'exit 0' TERM INT
rm -f "$READY"
unavailable=0
while :; do
  if capture_ready; then
    : >"$READY"
    unavailable=0
  else
    rm -f "$READY"
    if [ "$unavailable" = 0 ]; then
      echo 'nats-advisories capture is unavailable, nearing capacity or reset. Check the leaf link and backlog.' >&2
      unavailable=1
    fi
  fi
  sleep 5 &
  wait "$!"
done
