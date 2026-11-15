#!/usr/bin/env bash
# End-to-end test of compose/nats against the NATS of compose/infra.yaml, with the local values of
# compose/.env.example. Covers: the three streams and their limits, a backend that publishes its
# own subjects only, events read through consumers and never through a subscription, the restricted
# stream read by notification only, inboxes kept apart, the dead-letter path, streams no backend
# can change, a lost stream created again, and the hashes that make a host restart the broker.
#
#   bash compose/tests/nats-permissions.sh
#
# It creates and removes the Compose project cadenway-test-nats with its own volumes: it never
# touches the local stack, and must never run on a Cadenway host.
#
# The assertions are strings evaluated by `check`, so they expand late on purpose.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# Git Bash would rewrite the container paths given to `docker compose`.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
readonly PROJECT=cadenway-test-nats
readonly REFUSED='Permissions Violation'

compose() { docker compose -p "$PROJECT" --env-file .env.example -f infra.yaml "$@"; }
cleanup() { compose down --volumes --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# Runs the `nats` command line as a backend, with its own inbox prefix as a backend connects.
# Arguments: user (its local password is its name without hyphens, as compose/.env.example sets
# it: a password is letters and digits), then the command. Prints output and errors.
as() {
  local user=$1
  shift
  compose exec -T nats-streams nats --user "$user" --password "${user//-/}" \
    --inbox-prefix "_INBOX.$user" --timeout 1s "$@" 2>&1 || true
}
# A durable pull consumer as @cadenway/nest-messaging declares them.
# Arguments: user, stream, consumer name, filter subject.
add_consumer() {
  as "$1" consumer add "$2" "$3" --filter "$4" --pull --ack explicit \
    --deliver all --replay instant --max-deliver 5 --wait 30s --defaults
}
# Prints fields of a stream's configuration; jq runs in the container, which has it.
# Arguments: stream, jq filter.
stream_field() {
  compose exec -T -e STREAM="$1" -e FILTER="$2" nats-streams \
    sh -c 'nats stream info "$STREAM" --json | jq -r "$FILTER"' 2>&1 || true
}

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; echo "${OUT:-}" | tail -5; FAILED=1; fi; }
FAILED=0
OUT=''

echo '=== 1. a changed file restarts its container'
OUT=$(sed -n 's/^ *NATS_SERVER_CONF_SHA256: *//p' infra.yaml)
check 'NATS_SERVER_CONF_SHA256 is the hash of nats-server.conf' \
  '[[ $OUT == $(sha256sum nats/nats-server.conf | cut -c1-64) ]]'
OUT=$(sed -n 's/^ *ENSURE_STREAMS_SHA256: *//p' infra.yaml)
check 'ENSURE_STREAMS_SHA256 is the hash of ensure-streams.sh' \
  '[[ $OUT == $(sha256sum nats/ensure-streams.sh | cut -c1-64) ]]'

compose up -d --wait nats nats-streams >/dev/null 2>&1

echo '=== 2. the streams exist, as declared'
OUT=$(stream_field EVENTS '[.config.subjects[0], .config.storage, .config.max_age, .config.max_bytes, .config.duplicate_window] | join(" ")')
check 'EVENTS on evt.>, file storage, seven days, 1 GiB, two-minute window' \
  '[[ $OUT == "evt.> file 604800000000000 1073741824 120000000000" ]]'
OUT=$(stream_field EVENTS_RESTRICTED '[.config.subjects[0], .config.storage, .config.max_age] | join(" ")')
check 'EVENTS_RESTRICTED on restricted.>' '[[ $OUT == "restricted.> file 604800000000000" ]]'
OUT=$(stream_field EVENTS_DLQ '[.config.subjects[0], .config.storage, .config.max_age] | join(" ")')
check 'EVENTS_DLQ on dlq.>, thirty days' '[[ $OUT == "dlq.> file 2592000000000000" ]]'

echo '=== 3. a backend publishes its own subjects only'
OUT=$(as task request evt.task.created.v1 '{"id":"CAD-482"}')
check 'task publishes a task event' '[[ $OUT == *"\"stream\":\"EVENTS\""* ]]'
OUT=$(as task request evt.member.joined.v1 '{}')
check 'task cannot publish an organization event' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as api-gateway request evt.api-usage.recorded.v1 '{}')
check 'the API gateway publishes its usage event' '[[ $OUT == *"\"stream\":\"EVENTS\""* ]]'
OUT=$(as api-gateway request evt.task.created.v1 '{}')
check 'and no other event' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as search request evt.task.created.v1 '{}')
check 'search publishes nothing' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as realtime-gateway request evt.task.created.v1 '{}')
check 'the realtime gateway publishes nothing' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(compose exec -T nats-streams nats --user task --password wrong rtt 2>&1 || true)
check 'a wrong password is refused' '[[ $OUT == *"Authorization Violation"* ]]'
OUT=$(compose exec -T -e NATS_USER= -e NATS_PASSWORD= nats-streams nats rtt 2>&1 || true)
check 'a connection without a user is refused' '[[ $OUT == *"Authorization Violation"* ]]'

echo '=== 4. events are read through consumers, not subscriptions'
OUT=$(add_consumer search EVENTS search__index-task 'evt.task.>')
check 'search creates a consumer on EVENTS' '[[ $OUT == *"Unprocessed Messages: 1"* ]]'
OUT=$(as search consumer next EVENTS search__index-task --count 1 --ack)
check 'reads and acknowledges the event' '[[ $OUT == *CAD-482* && $OUT == *"Acknowledged message"* ]]'
OUT=$(as search sub 'evt.>' --count 1)
check 'cannot subscribe to evt.>' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(add_consumer api-gateway EVENTS api-gateway__spy 'evt.>')
check 'the API gateway cannot create a consumer' '[[ $OUT == *"$REFUSED for Publish"* ]]'

echo '=== 5. the restricted events are published by identity and read by notification only'
OUT=$(as identity request restricted.security-email.sign-in-code-issued.v1 '{"code":"482913"}')
check 'identity publishes a restricted event' '[[ $OUT == *"\"stream\":\"EVENTS_RESTRICTED\""* ]]'
OUT=$(as task request restricted.security-email.sign-in-code-issued.v1 '{}')
check 'task cannot publish one' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(add_consumer notification EVENTS_RESTRICTED notification__security-email 'restricted.>')
check 'notification creates its consumer' '[[ $OUT == *"Unprocessed Messages: 1"* ]]'
for user in identity task search realtime-gateway api-gateway; do
  OUT=$(as "$user" sub 'restricted.>' --count 1)
  check "$user cannot subscribe to restricted.>" '[[ $OUT == *"$REFUSED for Subscription"* ]]'
  OUT=$(add_consumer "$user" EVENTS_RESTRICTED "${user}__spy" 'restricted.>')
  check "$user cannot create a consumer on the stream" \
    '[[ $OUT == *"$REFUSED for Publish"* && $OUT != *"Unprocessed Messages"* ]]'
  OUT=$(as "$user" consumer next EVENTS_RESTRICTED notification__security-email --count 1 --ack)
  check "$user cannot pull from the consumer of notification" \
    '[[ $OUT == *"$REFUSED for Publish"* && $OUT != *482913* ]]'
  OUT=$(as "$user" stream get EVENTS_RESTRICTED 1)
  check "$user cannot read the message by its sequence" \
    '[[ $OUT == *"$REFUSED for Publish"* && $OUT != *482913* ]]'
done
OUT=$(as notification sub 'restricted.>' --count 1)
check 'notification itself cannot subscribe: consumers only' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(as notification consumer next EVENTS_RESTRICTED notification__security-email --count 1 --ack)
check 'notification reads the code through its consumer' \
  '[[ $OUT == *482913* && $OUT == *"Acknowledged message"* ]]'

echo '=== 6. a backend listens to its own inbox only'
OUT=$(as task sub '_INBOX.notification.>' --count 1)
check 'task cannot listen to the replies of notification' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(as task sub '_INBOX.>' --count 1)
check 'nor to every inbox' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(compose exec -T nats-streams nats --user task --password task --timeout 2s \
  request evt.task.created.v1 '{}' 2>&1 || true)
check 'the default inbox prefix is refused too' '[[ $OUT == *"$REFUSED for Subscription"* ]]'

echo '=== 7. rebuilds are plain subjects, one consumer each'
OUT=$(as task sub 'rebuild.search.>' --count 1)
check 'task cannot listen to the rebuild of search' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
compose exec -T nats-streams sh -c 'nats --user search --password search \
  --inbox-prefix _INBOX.search sub "rebuild.search.>" --count 1 >/tmp/rebuild 2>&1 &'
sleep 1
OUT=$(as task pub rebuild.search.task '{"id":"CAD-482"}')
sleep 1
OUT=$OUT$(compose exec -T nats-streams cat /tmp/rebuild)
check 'task re-emits a task for search' '[[ $OUT != *"$REFUSED"* && $OUT == *CAD-482* ]]'
OUT=$(as task pub rebuild.search.member '{}')
check 'but not an entity of another service' '[[ $OUT == *"$REFUSED for Publish"* ]]'

echo '=== 8. dead letters: notification copies, operators read'
compose exec -T nats-streams sh -c 'nats --user notification --password notification \
  --inbox-prefix _INBOX.notification \
  sub "\$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS.>" --count 1 >/tmp/advisory 2>&1 &'
sleep 1
# One delivery, to acknowledge within a second: read once and left alone, the message is given up.
as search consumer add EVENTS search__poison --filter 'evt.task.>' --pull --ack explicit \
  --deliver all --replay instant --max-deliver 1 --wait 1s --defaults >/dev/null
as search consumer next EVENTS search__poison --count 1 --no-ack >/dev/null
sleep 3
OUT=$(compose exec -T nats-streams cat /tmp/advisory)
check 'notification receives the advisory of a message given up on' \
  '[[ $OUT == *"max_deliver"* && $OUT == *search__poison* ]]'
OUT=$(as notification stream get EVENTS 1)
check 'reads the failed message by its sequence' '[[ $OUT == *CAD-482* ]]'
OUT=$(as notification request dlq.search__poison.evt.task.created.v1 '{"id":"CAD-482"}')
check 'copies it into EVENTS_DLQ' '[[ $OUT == *"\"stream\":\"EVENTS_DLQ\""* ]]'
OUT=$(as task request dlq.search__poison.evt.task.created.v1 '{}')
check 'no other backend writes a dead letter' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as task sub '$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS.>' --count 1)
check 'nor listens to the advisories' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(as task stream get EVENTS 1)
check 'nor reads a message by its sequence' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(add_consumer notification EVENTS_DLQ notification__spy 'dlq.>')
check 'no backend consumes the dead letters' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(compose exec -T nats-streams nats stream get EVENTS_DLQ 1 2>&1 || true)
check 'an operator reads them from the nats-streams container' '[[ $OUT == *CAD-482* ]]'

echo '=== 9. no backend changes a stream; a lost stream comes back'
OUT=$(as task stream rm EVENTS --force)
check 'a backend cannot delete a stream' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as task stream purge EVENTS --force)
check 'nor purge it' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as task stream add OTHER --subjects 'other.>' --defaults)
check 'nor create one' '[[ $OUT == *"$REFUSED for Publish"* ]]'
compose exec -T nats-streams nats stream rm EVENTS_DLQ --force >/dev/null 2>&1
OUT=missing
for _ in $(seq 1 45); do
  if compose exec -T nats-streams nats stream info EVENTS_DLQ >/dev/null 2>&1; then
    OUT=back
    break
  fi
  sleep 2
done
check 'a deleted stream is created again within the check interval' '[[ $OUT == back ]]'
OUT=$(compose ps --format '{{.Service}} {{.Health}}' nats-streams)
check 'and the container is healthy again' '[[ $OUT == "nats-streams healthy" ]]'

exit "$FAILED"
