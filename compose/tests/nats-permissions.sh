#!/usr/bin/env bash
# End-to-end test of compose/nats against the NATS of compose/infra.yaml, with the local values of
# compose/.env.example. Covers: the consumers granted by name, the three streams and their limits,
# a backend that publishes its own subjects only, events read through consumers and never through
# a subscription, the restricted stream read by notification only, inboxes kept apart, the
# dead-letter path, streams no backend can change, a lost stream created again, an existing stream
# brought to its declaration, the hashes that make a host restart the broker, each granted consumer
# used by its owner and by no other backend, and the names and filters nobody was given.
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

# The consumers nats/nats-server.conf grants, one per line: the user that owns it, its stream, its
# name, its filter subject, the user that publishes that event, and another backend that tries to
# use the consumer (section 12 then tries one of them as every other backend). Section 2 fails when
# this list and the configuration differ, so a grant always comes with its test.
readonly CONSUMERS='
identity EVENTS identity-service__project-member-joined evt.member.joined.v1 organization organization
identity EVENTS identity-service__project-member-role-changed evt.member.role-changed.v1 organization notification
identity EVENTS identity-service__project-member-removed evt.member.removed.v1 organization task
organization EVENTS organization-service__project-user-signed-up evt.user.signed-up.v1 identity identity
organization EVENTS organization-service__project-user-email-verified evt.user.email-verified.v1 identity notification
organization EVENTS organization-service__project-user-profile-updated evt.user.profile-updated.v1 identity search
organization EVENTS organization-service__project-user-email-changed evt.user.email-changed.v1 identity notification
organization EVENTS organization-service__project-user-two-step evt.user.two-step-verification-changed.v1 identity notification
organization EVENTS organization-service__remove-deleted-user evt.user.deleted.v1 identity task
task EVENTS task-service__project-member-joined evt.member.joined.v1 organization identity
task EVENTS task-service__project-member-role-changed evt.member.role-changed.v1 organization notification
task EVENTS task-service__project-member-removed evt.member.removed.v1 organization search
notification EVENTS notification-service__request-invitation-email evt.invitation.issued.v1 organization organization
notification EVENTS notification-service__request-password-changed-email evt.user.password-changed.v1 identity organization
notification EVENTS notification-service__request-email-changed-email evt.user.email-changed.v1 identity organization
notification EVENTS notification-service__request-new-device-email evt.session.opened-on-new-device.v1 identity realtime-gateway
notification EVENTS notification-service__request-deletion-scheduled-email evt.user.deletion-scheduled.v1 identity identity
notification EVENTS notification-service__request-deletion-cancelled-email evt.user.deletion-cancelled.v1 identity billing
notification EVENTS notification-service__request-two-step-email evt.user.two-step-verification-changed.v1 identity organization
notification EVENTS_RESTRICTED notification-service__request-code-email restricted.one-time-code.issued.v1 identity identity
notification EVENTS_RESTRICTED notification-service__request-password-reset-email restricted.password-reset-link.issued.v1 identity organization
'
# What `nats consumer next` prints of a delivery: the attempt, the consumer and stream sequences.
readonly DELIVERY='tries: ([0-9]+) / cons seq: ([0-9]+) / str seq: ([0-9]+)'
# The system subjects a backend may have besides those of its consumers: the start-up checks of
# @cadenway/nest-messaging, and for notification alone the reads and advisories of the dead-letter
# worker.
readonly STREAM_INFO='^publish \$JS\.API\.(INFO|STREAM\.NAMES|STREAM\.INFO\.(EVENTS|EVENTS_RESTRICTED|EVENTS_DLQ))$'
readonly CONSUMER_API='^publish \$JS\.(API\.CONSUMER\.(CREATE|INFO|MSG\.NEXT)|ACK)\.'
readonly DEAD_LETTER_READ='^publish \$JS\.API\.STREAM\.MSG\.GET\.(EVENTS|EVENTS_RESTRICTED)$'
readonly DEAD_LETTER_ADVISORY='^subscribe \$JS\.EVENT\.ADVISORY\.CONSUMER\.(MAX_DELIVERIES|MSG_TERMINATED)\.(EVENTS|EVENTS_RESTRICTED)\.>$'

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
# Prints the body of the request @cadenway/nest-messaging sends on
# $JS.API.CONSUMER.CREATE.<stream>.<consumer>.<filter>. Arguments: stream, consumer, filter subject.
consumer_config() {
  printf '{"stream_name":"%s","action":"create","config":{"name":"%s","durable_name":"%s",' \
    "$1" "$2" "$2"
  printf '"filter_subject":"%s","ack_policy":"explicit","deliver_policy":"all",' "$3"
  printf '"max_deliver":5,"ack_wait":30000000000}}'
}
# Creates a durable pull consumer as @cadenway/nest-messaging does, on the subject it uses.
# Arguments: user, stream, consumer, filter subject. Prints the reply or the refusal.
create_consumer() {
  as "$1" request "\$JS.API.CONSUMER.CREATE.$2.$3.$4" "$(consumer_config "$2" "$3" "$4")"
}
# Prints each subject nats/nats-server.conf allows a backend user, with the user and the right:
# `identity publish $JS.API.CONSUMER.INFO.EVENTS.identity-service__project-member-joined`. The
# `admin` user is left out.
granted_subjects() {
  awk '
    /^ *#/ { next }
    /^ *user:/ { user = $2; gsub(/"/, "", user); right = ""; next }
    user != "" && user != "admin" {
      for (i = 1; i <= NF; i++) {
        if ($i == "publish:") right = "publish"
        else if ($i == "subscribe:") right = "subscribe"
        else if (right != "" && $i ~ /^\[?"/) {
          subject = $i
          gsub(/[]["{},]/, "", subject)
          print user, right, subject
        }
      }
    }' nats/nats-server.conf
}
# Prints fields of a stream's configuration; jq runs in the container, which has it.
# Arguments: stream, jq filter.
stream_field() {
  compose exec -T -e STREAM="$1" -e FILTER="$2" nats-streams \
    sh -c 'nats stream info "$STREAM" --json | jq -r "$FILTER"' 2>&1 || true
}
# Waits up to a minute for a field of a stream to take a value; prints the last value read.
# Arguments: stream, jq filter, expected value.
wait_for() {
  local value=''
  for _ in $(seq 1 30); do
    value=$(stream_field "$1" "$2")
    [[ $value == "$3" ]] && break
    sleep 2
  done
  printf '%s\n' "$value"
}
# Waits up to a minute for nats-streams to be healthy, which a restart resets; prints its state.
wait_healthy() {
  local state=''
  for _ in $(seq 1 30); do
    state=$(compose ps --format '{{.Service}} {{.Health}}' nats-streams)
    [[ $state == 'nats-streams healthy' ]] && break
    sleep 2
  done
  printf '%s\n' "$state"
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

echo '=== 2. each consumer is granted by its exact name to its owner, and nothing else is'
mapfile -t GRANTS < <(granted_subjects)
CONSUMER_GRANTS=()
CREATES=()
OUT=''
for grant in "${GRANTS[@]}"; do
  read -r user right subject <<<"$grant"
  if [[ $subject == [*\>]* ]]; then
    # A first token that is a wildcard would match the JetStream API and every acknowledgement.
    OUT+=" $user:$subject"
  elif [[ $subject != \$* || "$right $subject" =~ $STREAM_INFO ]]; then
    continue
  elif [[ "$right $subject" =~ $CONSUMER_API ]]; then
    CONSUMER_GRANTS+=("$user $subject")
    stem=$subject
    [[ $stem == '$JS.ACK.'* ]] && stem=${stem%.>}
    [[ $stem == *[*\>]* ]] && OUT+=" $user:$subject"
    if [[ $subject =~ ^\$JS\.API\.CONSUMER\.CREATE\.([^.]+)\.([^.]+)\.(.+)$ ]]; then
      CREATES+=("$user ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}")
    fi
  elif [[ $user == notification && ("$right $subject" =~ $DEAD_LETTER_READ ||
    "$right $subject" =~ $DEAD_LETTER_ADVISORY) ]]; then
    continue
  else
    OUT+=" $user:$subject"
  fi
done
check 'no backend has a system subject beyond its consumers, its streams and the dead letters' \
  '[[ ${#GRANTS[@]} -gt 0 && -z $OUT ]]'
EXPECTED=$(sed '/^$/d' <<<"$CONSUMERS" | cut -d ' ' -f 1-4 | sort)
OUT=$(printf '%s\n' "${CREATES[@]}" | sort)
check 'the consumers of nats-server.conf are the ones this test covers' '[[ $OUT == "$EXPECTED" ]]'
OUT=''
for row in "${CREATES[@]}"; do
  read -r user stream consumer _ <<<"$row"
  for subject in "\$JS.API.CONSUMER.INFO.$stream.$consumer" \
    "\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer" "\$JS.ACK.$stream.$consumer.>"; do
    printf '%s\n' "${CONSUMER_GRANTS[@]}" | grep -Fqx -- "$user $subject" || OUT+=" $user:$subject"
  done
  [[ $consumer == "$user-service__"* || $consumer == "${user}__"* ]] || OUT+=" $user:$consumer"
done
check 'each has its four subjects, granted to the service its name starts with' '[[ -z $OUT ]]'
OUT=$(printf '%s\n' "${CREATES[@]}" | awk '$2 == "EVENTS_RESTRICTED" && $1 != "notification"')
check 'only notification has a consumer on EVENTS_RESTRICTED (decision D7)' '[[ -z $OUT ]]'
OUT=$((${#CONSUMER_GRANTS[@]} - 4 * ${#CREATES[@]}))
check 'and no user has any other consumer or acknowledgement subject' '[[ $OUT == 0 ]]'

compose up -d --wait nats nats-streams >/dev/null 2>&1

echo '=== 3. the streams exist, as declared'
OUT=$(stream_field EVENTS '[.config.subjects[0], .config.storage, .config.max_age, .config.max_bytes, .config.duplicate_window] | join(" ")')
check 'EVENTS on evt.>, file storage, seven days, 1 GiB, two-minute window' \
  '[[ $OUT == "evt.> file 604800000000000 1073741824 120000000000" ]]'
OUT=$(stream_field EVENTS_RESTRICTED \
  '.config | [.subjects[0], .storage, .retention, .max_age, .max_bytes] | join(" ")')
check 'EVENTS_RESTRICTED on restricted.>, limits retention, one hour, 64 MiB' \
  '[[ $OUT == "restricted.> file limits 3600000000000 67108864" ]]'
OUT=$(stream_field EVENTS_DLQ '[.config.subjects[0], .config.storage, .config.max_age] | join(" ")')
check 'EVENTS_DLQ on dlq.>, thirty days' '[[ $OUT == "dlq.> file 2592000000000000" ]]'

echo '=== 4. a backend publishes its own subjects only'
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

echo '=== 5. events are read through consumers, not subscriptions'
OUT=$(as search sub 'evt.>' --count 1)
check 'search cannot subscribe to evt.>' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(as identity sub 'evt.member.>' --count 1)
check 'nor identity to the member events it consumes' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
create='$JS.API.CONSUMER.CREATE.EVENTS.api-gateway__spy.evt.task.created.v1'
OUT=$(create_consumer api-gateway EVENTS api-gateway__spy evt.task.created.v1)
check 'the API gateway cannot create a consumer' \
  '[[ $OUT == *"$REFUSED for Publish to \"$create\""* && $OUT != *CAD-482* ]]'

echo '=== 6. the restricted events are published by identity and read by notification only'
code=notification-service__request-code-email
OUT=$(as identity request restricted.one-time-code.issued.v1 '{"code":"482913"}')
check 'identity publishes a restricted event' '[[ $OUT == *"\"stream\":\"EVENTS_RESTRICTED\""* ]]'
OUT=$(as task request restricted.one-time-code.issued.v1 '{}')
check 'task cannot publish one' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(create_consumer notification EVENTS_RESTRICTED "$code" restricted.one-time-code.issued.v1)
check 'notification creates its consumer' '[[ $OUT == *"\"name\":\"$code\""* && $OUT == *"\"num_pending\":1"* ]]'
for user in identity task search realtime-gateway api-gateway; do
  OUT=$(as "$user" sub 'restricted.>' --count 1)
  check "$user cannot subscribe to restricted.>" '[[ $OUT == *"$REFUSED for Subscription"* ]]'
  OUT=$(create_consumer "$user" EVENTS_RESTRICTED "${user}__spy" restricted.one-time-code.issued.v1)
  check "$user cannot create a consumer on the stream" \
    '[[ $OUT == *"$REFUSED for Publish"* && $OUT != *"\"num_pending\""* ]]'
  OUT=$(as "$user" request "\$JS.API.CONSUMER.MSG.NEXT.EVENTS_RESTRICTED.$code" \
    '{"batch":1,"expires":500000000}')
  check "$user cannot pull from the consumer of notification" \
    '[[ $OUT == *"$REFUSED for Publish"* && $OUT != *482913* ]]'
  OUT=$(as "$user" stream get EVENTS_RESTRICTED 1)
  check "$user cannot read the message by its sequence" \
    '[[ $OUT == *"$REFUSED for Publish"* && $OUT != *482913* ]]'
done
OUT=$(as notification sub 'restricted.>' --count 1)
check 'notification itself cannot subscribe: consumers only' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(as notification consumer next EVENTS_RESTRICTED "$code" --count 1 --ack)
check 'notification reads the code through its consumer' \
  '[[ $OUT == *482913* && $OUT == *"Acknowledged message"* && $OUT != *"$REFUSED"* ]]'
# Acknowledged on the reply subject the server gave the delivery: it falls inside the grant.
OUT=$(as notification consumer info EVENTS_RESTRICTED "$code" --json)
check 'and the broker has its acknowledgement' \
  '[[ $OUT == *"\"num_ack_pending\": 0"* && $OUT == *"\"num_pending\": 0"* ]]'

echo '=== 7. a backend listens to its own inbox only'
OUT=$(as task sub '_INBOX.notification.>' --count 1)
check 'task cannot listen to the replies of notification' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(as task sub '_INBOX.>' --count 1)
check 'nor to every inbox' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(compose exec -T nats-streams nats --user task --password task --timeout 2s \
  request evt.task.created.v1 '{}' 2>&1 || true)
check 'the default inbox prefix is refused too' '[[ $OUT == *"$REFUSED for Subscription"* ]]'

echo '=== 8. rebuilds are plain subjects, one consumer each'
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

echo '=== 9. dead letters: notification copies, operators read'
compose exec -T nats-streams sh -c 'nats --user notification --password notification \
  --inbox-prefix _INBOX.notification \
  sub "\$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS.>" --count 1 >/tmp/advisory 2>&1 &'
sleep 1
# One delivery, to acknowledge within a second: read once and left alone, the message is given up.
# The consumer is an operator's, made with `admin`: the advisory is the same whoever owns the
# consumer, and no backend may open a consumer it was not given.
compose exec -T nats-streams nats consumer add EVENTS operator__poison --filter 'evt.task.>' \
  --pull --ack explicit --deliver all --replay instant --max-deliver 1 --wait 1s --defaults \
  >/dev/null 2>&1
compose exec -T nats-streams nats consumer next EVENTS operator__poison --count 1 --no-ack \
  >/dev/null 2>&1
sleep 3
OUT=$(compose exec -T nats-streams cat /tmp/advisory)
check 'notification receives the advisory of a message given up on' \
  '[[ $OUT == *"max_deliver"* && $OUT == *operator__poison* ]]'
OUT=$(as notification stream get EVENTS 1)
check 'reads the failed message by its sequence' '[[ $OUT == *CAD-482* ]]'
OUT=$(as notification request dlq.operator__poison.evt.task.created.v1 '{"id":"CAD-482"}')
check 'copies it into EVENTS_DLQ' '[[ $OUT == *"\"stream\":\"EVENTS_DLQ\""* ]]'
OUT=$(as task request dlq.operator__poison.evt.task.created.v1 '{}')
check 'no other backend writes a dead letter' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as task sub '$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS.>' --count 1)
check 'nor listens to the advisories' '[[ $OUT == *"$REFUSED for Subscription"* ]]'
OUT=$(as task stream get EVENTS 1)
check 'nor reads a message by its sequence' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(create_consumer notification EVENTS_DLQ notification-service__read-dead-letters \
  dlq.operator__poison.evt.task.created.v1)
check 'no backend consumes the dead letters' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(compose exec -T nats-streams nats stream get EVENTS_DLQ 1 2>&1 || true)
check 'an operator reads them from the nats-streams container' '[[ $OUT == *CAD-482* ]]'

echo '=== 10. no backend changes a stream; a lost stream comes back'
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

echo '=== 11. an existing stream is brought to the declaration when nats-streams starts'
# The restricted stream as the former declaration left it on a host: seven days.
compose exec -T nats-streams nats stream edit EVENTS_RESTRICTED --max-age 7d --force >/dev/null 2>&1
OUT=$(stream_field EVENTS_RESTRICTED '.config.max_age')
check 'the stream is set back to seven days' '[[ $OUT == 604800000000000 ]]'
compose restart nats-streams >/dev/null 2>&1
OUT=$(wait_for EVENTS_RESTRICTED '.config.max_age' 3600000000000)
check 'one hour again after a restart' '[[ $OUT == 3600000000000 ]]'
OUT=$(stream_field EVENTS_RESTRICTED \
  '[.config.retention, .config.max_bytes, .state.messages] | join(" ")')
check 'same retention and size cap, the stored code kept' '[[ $OUT == "limits 67108864 1" ]]'
OUT=$(wait_healthy)
check 'and the container is healthy' '[[ $OUT == "nats-streams healthy" ]]'
compose restart nats-streams >/dev/null 2>&1
OUT=$(wait_healthy)
check 'a start with nothing to change is healthy too' '[[ $OUT == "nats-streams healthy" ]]'

echo '=== 12. each granted consumer works for its owner, and for no other backend'
# Each step uses the subject @cadenway/nest-messaging uses, sent as is, so a refusal names it. The
# other backend acknowledges on the reply subject of a message the owner holds: had it the right,
# the message would leave the owner. The rows are read before the loop, since `docker compose exec`
# reads the standard input of the commands inside it.
#
# Two consumers may filter one event (evt.user.email-changed.v1 feeds organization and
# notification): the later one finds every copy published here, none taken by the acknowledgements
# of the other, so the pending counts are kept per filter.
mapfile -t ROWS < <(sed '/^$/d' <<<"$CONSUMERS")
declare -A SENT=()
for row in "${ROWS[@]}"; do
  read -r owner stream consumer filter publisher other <<<"$row"
  create="\$JS.API.CONSUMER.CREATE.$stream.$consumer.$filter"
  info="\$JS.API.CONSUMER.INFO.$stream.$consumer"
  next="\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer"
  delete="\$JS.API.CONSUMER.DELETE.$stream.$consumer"
  OUT=$(as "$publisher" request "$filter" "{\"event\":\"$filter\"}")
  check "$publisher publishes $filter" '[[ $OUT == *"\"stream\":\"$stream\""* ]]'
  SENT[$filter]=$((${SENT[$filter]:-0} + 1))
  pending=${SENT[$filter]}
  left=$((pending - 1))
  OUT=$(as "$owner" request "$filter" '{}')
  check "$owner cannot publish it" '[[ $OUT == *"$REFUSED for Publish to \"$filter\""* ]]'
  OUT=$(create_consumer "$other" "$stream" "$consumer" "$filter")
  check "$other cannot create $consumer" '[[ $OUT == *"$REFUSED for Publish to \"$create\""* ]]'
  OUT=$(create_consumer "$owner" "$stream" "$consumer" "$filter")
  check "$owner creates it, or aligns it" \
    '[[ $OUT == *"\"name\":\"$consumer\""* && $OUT == *"\"num_pending\":$pending"* && $OUT != *"\"error\""* ]]'
  OUT=$(as "$other" request "$info" '')
  check "$other cannot read it" \
    '[[ $OUT == *"$REFUSED for Publish to \"$info\""* && $OUT != *"\"num_pending\""* ]]'
  OUT=$(as "$other" request "$next" '{"batch":1,"expires":500000000}')
  check "$other cannot pull from it" \
    '[[ $OUT == *"$REFUSED for Publish to \"$next\""* && $OUT != *"\"event\""* ]]'
  OUT=$(as "$owner" consumer next "$stream" "$consumer" --count 1 --no-ack)
  check "$owner pulls $filter from it" '[[ $OUT == *"{\"event\":\"$filter\"}"* ]]'
  # The reply subject of that delivery: attempt, stream and consumer sequences, time, pending.
  ack="\$JS.ACK.$stream.$consumer.unknown"
  if [[ $OUT =~ $DELIVERY ]]; then
    ack="\$JS.ACK.$stream.$consumer.${BASH_REMATCH[1]}.${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.0.0"
  fi
  OUT=$(as "$other" pub "$ack" '+ACK')
  check "$other cannot acknowledge on it" '[[ $OUT == *"$REFUSED for Publish to \"$ack\""* ]]'
  OUT=$(as "$owner" consumer info "$stream" "$consumer" --json)
  check 'the message is still held by the owner' '[[ $OUT == *"\"num_ack_pending\": 1"* ]]'
  OUT=$(as "$owner" pub "$ack" '+ACK')
  OUT=$OUT$(as "$owner" consumer info "$stream" "$consumer" --json)
  check "$owner acknowledges it" \
    '[[ $OUT != *"$REFUSED"* && $OUT == *"\"num_ack_pending\": 0"* && $OUT == *"\"num_pending\": $left"* ]]'
  OUT=$(as "$other" request "$delete" '')
  check "$other cannot delete it" '[[ $OUT == *"$REFUSED for Publish to \"$delete\""* ]]'
  OUT=$(compose exec -T nats-streams nats consumer info "$stream" "$consumer" --json 2>&1 || true)
  check 'which is still there, on its filter' \
    '[[ $OUT == *"\"filter_subject\": \"$filter\""* ]]'
done
# Every other backend, on one consumer that holds a message.
held=identity-service__project-member-joined
as organization request evt.member.joined.v1 '{"event":"held"}' >/dev/null
OUT=$(as identity consumer next EVENTS "$held" --count 1 --no-ack)
ack="\$JS.ACK.EVENTS.$held.unknown"
if [[ $OUT =~ $DELIVERY ]]; then
  ack="\$JS.ACK.EVENTS.$held.${BASH_REMATCH[1]}.${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.0.0"
fi
create="\$JS.API.CONSUMER.CREATE.EVENTS.$held.evt.member.joined.v1"
info="\$JS.API.CONSUMER.INFO.EVENTS.$held"
next="\$JS.API.CONSUMER.MSG.NEXT.EVENTS.$held"
delete="\$JS.API.CONSUMER.DELETE.EVENTS.$held"
for user in organization billing task document storage notification automation integration \
  search api-gateway realtime-gateway; do
  OUT=$(create_consumer "$user" EVENTS "$held" evt.member.joined.v1)
  OUT+=$(as "$user" request "$info" '')
  OUT+=$(as "$user" request "$next" '{"batch":1,"expires":500000000}')
  OUT+=$(as "$user" pub "$ack" '+ACK')
  OUT+=$(as "$user" request "$delete" '')
  check "$user is refused the create, read, pull, acknowledgement and deletion of $held" \
    '[[ $OUT == *"$REFUSED for Publish to \"$create\""* && $OUT == *"$REFUSED for Publish to \"$info\""*
      && $OUT == *"$REFUSED for Publish to \"$next\""* && $OUT == *"$REFUSED for Publish to \"$ack\""*
      && $OUT == *"$REFUSED for Publish to \"$delete\""* && $OUT != *"\"event\":\"held\""* ]]'
done
OUT=$(as identity consumer info EVENTS "$held" --json)
check 'the message is still held by identity' '[[ $OUT == *"\"num_ack_pending\": 1"* ]]'
OUT=$(as identity pub "$ack" '+ACK')
OUT=$OUT$(as identity consumer info EVENTS "$held" --json)
check 'which acknowledges it' '[[ $OUT != *"$REFUSED"* && $OUT == *"\"num_ack_pending\": 0"* ]]'
compose exec -T nats-streams sh -c 'nats --user notification --password notification \
  --inbox-prefix _INBOX.notification sub "rebuild.notification.>" --count 1 \
  >/tmp/rebuild-invitation 2>&1 &'
sleep 1
OUT=$(as organization pub rebuild.notification.invitation '{"id":"invitation-1"}')
sleep 1
OUT=$OUT$(compose exec -T nats-streams cat /tmp/rebuild-invitation)
check 'organization re-emits an invitation for notification' \
  '[[ $OUT != *"$REFUSED"* && $OUT == *invitation-1* ]]'
OUT=$(as identity pub rebuild.notification.invitation '{}')
check 'and no other backend does' \
  '[[ $OUT == *"$REFUSED for Publish to \"rebuild.notification.invitation\""* ]]'

echo '=== 13. a name or a filter nobody was given is refused, to its would-be owner too'
# Names a backend might give a new handler before its grant is deployed.
for row in \
  'identity EVENTS identity-service__project-organization-created evt.organization.created.v1' \
  'organization EVENTS organization-service__project-session-revoked evt.session.revoked.v1' \
  'notification EVENTS notification-service__request-member-email evt.member.joined.v1' \
  'notification EVENTS_RESTRICTED notification-service__audit-code restricted.one-time-code.issued.v1' \
  'search EVENTS search-service__index-task evt.task.created.v1' \
  'realtime-gateway EVENTS realtime-gateway__relay-task evt.task.created.v1'; do
  read -r user stream consumer filter <<<"$row"
  create="\$JS.API.CONSUMER.CREATE.$stream.$consumer.$filter"
  info="\$JS.API.CONSUMER.INFO.$stream.$consumer"
  next="\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer"
  OUT=$(create_consumer "$user" "$stream" "$consumer" "$filter")
  check "$user cannot create $consumer" '[[ $OUT == *"$REFUSED for Publish to \"$create\""* ]]'
  OUT=$(as "$user" request "$info" '')
  check 'nor read it' '[[ $OUT == *"$REFUSED for Publish to \"$info\""* ]]'
  OUT=$(as "$user" request "$next" '{"batch":1,"expires":500000000}')
  check 'nor pull from it' '[[ $OUT == *"$REFUSED for Publish to \"$next\""* ]]'
done
own=identity-service__project-member-joined
create="\$JS.API.CONSUMER.CREATE.EVENTS.$own.evt.organization.created.v1"
OUT=$(as identity request "$create" "$(consumer_config EVENTS "$own" evt.organization.created.v1)")
check 'identity cannot give its own consumer another filter' \
  '[[ $OUT == *"$REFUSED for Publish to \"$create\""* ]]'
create="\$JS.API.CONSUMER.CREATE.EVENTS.$own"
OUT=$(as identity request "$create" "$(consumer_config EVENTS "$own" evt.member.joined.v1)")
check 'nor create it without its filter in the subject' \
  '[[ $OUT == *"$REFUSED for Publish to \"$create\""* ]]'
create="\$JS.API.CONSUMER.DURABLE.CREATE.EVENTS.$own"
OUT=$(as identity request "$create" "$(consumer_config EVENTS "$own" evt.member.joined.v1)")
check 'nor through the former durable subject' \
  '[[ $OUT == *"$REFUSED for Publish to \"$create\""* ]]'
OUT=$(as identity request "\$JS.API.CONSUMER.CREATE.EVENTS.$own.evt.member.joined.v1" \
  "$(consumer_config EVENTS "$own" 'evt.>')")
check 'nor widen the filter in the body of its granted subject: the server refuses it' \
  '[[ $OUT != *"$REFUSED"* && $OUT == *"\"err_code\":10131"* ]]'
OUT=$(as identity request "\$JS.API.CONSUMER.CREATE.EVENTS.$own.evt.member.joined.v1" \
  "$(consumer_config EVENTS organization-service__project-user-signed-up evt.member.joined.v1)")
check 'nor reach the consumer of another backend through it: the server refuses that too' \
  '[[ $OUT != *"$REFUSED"* && $OUT == *"\"err_code\":10017"* ]]'
delete="\$JS.API.CONSUMER.DELETE.EVENTS.$own"
OUT=$(as identity request "$delete" '')
check 'nor delete it: an operator does' '[[ $OUT == *"$REFUSED for Publish to \"$delete\""* ]]'
OUT=$(compose exec -T nats-streams nats consumer info EVENTS "$own" --json 2>&1 || true)
check 'the consumer still filters its one event' \
  '[[ $OUT == *"\"filter_subject\": \"evt.member.joined.v1\""* ]]'

exit "$FAILED"
