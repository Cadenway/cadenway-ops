#!/usr/bin/env bash
# Runs against a disposable local Docker project, with the pinned NATS server and CLI.
# jq expressions reference jq variables, not shell variables.
# shellcheck disable=SC2016
set -euo pipefail
export MSYS_NO_PATHCONV=1 COMPOSE_DISABLE_ENV_FILE=1
export NATS_ADMIN_PASSWORD=admin
export NATS_ADVISORY_LEAF_PASSWORD="localLeaf${RANDOM}"
export NATS_ADVISORY_ADMIN_PASSWORD="localAdmin${RANDOM}"
export NATS_ADVISORY_READER_PASSWORD="localReader${RANDOM}"

cd "$(dirname "$0")/.."
readonly project="cadenway-test-advisories-${RANDOM}-${RANDOM}"
readonly stream=EVENTS_ADVISORIES
readonly durable=notification-dead-letter-advisories-v1
readonly latches=(REALTIME_AUTHORIZATION_ADVISORIES SEARCH_REBUILD_ADVISORIES BILLING_REBUILD_ADVISORIES)

compose() {
  docker --host "$docker_endpoint" compose --project-name "$project" --env-file .env.example \
    -f infra.yaml -f compose.advisories.local.yaml "$@"
}

cleanup() {
  compose down --timeout 2 --volumes >/dev/null
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

hub() {
  compose exec -T nats-streams nats --timeout 3s "$@"
}

observer() {
  compose exec -T nats-advisory-streams nats --timeout 3s "$@"
}

reader() {
  compose exec -T -e NATS_USER=notification -e NATS_PASSWORD="$NATS_ADVISORY_READER_PASSWORD" \
    nats-advisory-streams nats --timeout 3s --inbox-prefix _INBOX.notification "$@"
}

json() {
  compose exec -T nats-advisory-streams jq "$@"
}

await() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

ready() {
  compose exec -T nats-advisory-streams test -e /tmp/advisories-ready
}

unready() { ! ready; }

pending() {
  observer consumer info "$stream" "$durable" --json |
    json -e --argjson count "$1" '.num_pending == $count and .num_ack_pending == 0' >/dev/null
}

latch_identity() {
  local latch
  for latch in "${latches[@]}"; do
    hub stream info "$latch" --json | json -cS '{created, config}'
  done
}

latch_at() {
  hub stream info "$1" --json |
    json -e --argjson seq "$2" '.state.messages == 1 and .state.last_seq == $seq' >/dev/null
}

produce_advisories() {
  local source=$1 consumer=$2 subject=$3
  hub consumer add "$source" "$consumer" --defaults --filter "$subject" --pull \
    --ack explicit --deliver all --replay instant --max-deliver 1 --wait 1s >/dev/null
  for event in 1 2 3 4; do
    hub pub "$subject" "fixture-payload-$event" >/dev/null 2>&1
  done
  hub consumer next "$source" "$consumer" --count 2 --term >/dev/null
  hub consumer next "$source" "$consumer" --count 2 --no-ack >/dev/null
}

# Pin the verified endpoint for preflight, setup and cleanup.
docker_endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}') ||
  fail 'could not resolve the active Docker endpoint'
readonly docker_endpoint
case "$docker_endpoint" in
  unix:///*|npipe:////./pipe/*) ;;
  *) fail 'the disposable NATS test requires a local Docker socket or Windows named pipe' ;;
esac
unset DOCKER_CONTEXT DOCKER_HOST

for resource in container network volume; do
  existing=$(docker --host "$docker_endpoint" "$resource" ls -q \
    --filter "label=com.docker.compose.project=$project")
  [[ -z $existing ]] || fail 'Compose test project already exists'
done
trap cleanup EXIT

compose up -d --pull never --wait --wait-timeout 60 nats-streams nats-advisory-streams
before=$(latch_identity)
pending 0

produce_advisories EVENTS realtime-gateway__relay-task-purged evt.task.purged.v1
produce_advisories EVENTS search-service__index-task-created-v1 evt.task.created.v1
produce_advisories EVENTS billing-service__record-file-uploaded evt.file.uploaded.v1
produce_advisories EVENTS_RESTRICTED fixture__restricted restricted.one-time-code.issued.v1

await pending 16 || fail 'sixteen native advisories should accumulate without a reader'
for latch in "${latches[@]}"; do
  latch_at "$latch" 4 || fail "latched state of $latch"
done
echo 'PASS sixteen native advisories captured while the reader was offline'

# The observer serves from its own volume after a broker restart. The original latches still
# contain their latest advisory and their configurations and identities are unchanged.
compose restart --timeout 2 nats-advisories >/dev/null
await ready || fail 'capture helper should recover after the observer restarts'
await pending 16 || fail 'the unread burst should survive the observer restart'
[[ "$(latch_identity)" == "$before" ]] || fail 'original latch definitions or identities changed'
echo 'PASS observer restart preserves the burst and the three original latch identities'

reader consumer info "$stream" "$durable" --json |
  json -e --arg name "$durable" '.name == $name' >/dev/null
events=$(reader consumer next "$stream" "$durable" --count 16 --ack --raw)
printf '%s\n' "$events" |
  json -es '
    length == 16 and
    (unique_by([.stream, .consumer, .stream_seq, .type]) | length) == 16 and
    (group_by([.stream, .type]) | map([.[0].stream, .[0].type, length])) == [
      ["EVENTS", "io.nats.jetstream.advisory.v1.max_deliver", 6],
      ["EVENTS", "io.nats.jetstream.advisory.v1.terminated", 6],
      ["EVENTS_RESTRICTED", "io.nats.jetstream.advisory.v1.max_deliver", 2],
      ["EVENTS_RESTRICTED", "io.nats.jetstream.advisory.v1.terminated", 2]
    ]
  ' >/dev/null || fail 'reader did not receive all four advisory families exactly once'
await pending 0 || fail 'acknowledgements should drain only the capture stream'
observer stream info "$stream" --json | json -e '.state.messages == 0' >/dev/null
[[ "$(latch_identity)" == "$before" ]] || fail 'reading captured advisories changed a latch'
echo 'PASS the restricted reader can read and acknowledge all four advisory families'

for subject in "\$JS.API.STREAM.INFO.$stream" "\$JS.API.CONSUMER.INFO.$stream.fixture__other" \
  "\$JS.API.CONSUMER.DELETE.$stream.$durable"; do
  refusal=$(reader request "$subject" '{}' 2>&1 || true)
  [[ $refusal == *"Permissions Violation for Publish to \"$subject\""* ]] ||
    fail "reader publish should be refused on $subject"
done
if hub stream info "$stream" >/dev/null 2>&1; then fail 'the hub can see the capture stream'; fi
client_info=$(compose exec -T nats-streams nc -w 2 nats 4222 </dev/null)
[[ $client_info == 'INFO '* ]] || fail 'the application network should reach the NATS client port'
if port_result=$(compose exec -T nats-streams nc -w 2 nats 7422 </dev/null 2>&1) ||
  [[ $port_result == 'INFO '* ]]; then
  fail 'the application network should reject connections to the NATS leaf port'
fi
if leaf_result=$(compose exec -T -e NATS_USER=advisory-leaf \
  -e NATS_PASSWORD="$NATS_ADVISORY_LEAF_PASSWORD" nats-streams nats --timeout 2s stream info EVENTS 2>&1) ||
  [[ $leaf_result != *'Authorization Violation'* ]]; then
  fail 'the leaf credential was accepted on the ordinary NATS port'
fi
echo 'PASS stream management, other durables and broker domains are isolated'

compose stop --timeout 2 nats-advisories >/dev/null
await unready || fail 'a lost capture connection should fail readiness'
hub pub evt.task.purged.v1 fixture-emitted-in-gap >/dev/null 2>&1
hub consumer next EVENTS realtime-gateway__relay-task-purged --count 1 --term >/dev/null
await latch_at REALTIME_AUTHORIZATION_ADVISORIES 5 || fail 'source latch missed the event in the gap'
compose start nats-advisories >/dev/null
await ready || fail 'the capture link did not recover'
pending 0 || fail 'local transport unexpectedly replayed an uncaptured advisory'
hub pub evt.task.purged.v1 fixture-emitted-after-gap >/dev/null 2>&1
hub consumer next EVENTS realtime-gateway__relay-task-purged --count 1 --term >/dev/null
await pending 1 || fail 'new capture did not resume after observer outage'
echo 'PASS readiness detects an outage and capture resumes for newly emitted advisories'

observer consumer rm "$stream" "$durable" --force >/dev/null
await unready || fail 'loss of the original cursor should fail readiness'
if observer consumer info "$stream" "$durable" >/dev/null 2>&1; then
  fail 'replacement cursor hid the failure'
fi
echo 'PASS cursor loss fails readiness and calls for operator recovery'
