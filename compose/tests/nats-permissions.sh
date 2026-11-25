#!/usr/bin/env bash
# End-to-end test of compose/nats against the NATS of compose/infra.yaml, with the local values of
# compose/.env.example. Covers: the consumers granted by name, the three streams and their limits,
# the advisory latches, a backend that publishes its own subjects only, events
# read through consumers and never through a subscription, the restricted stream read by
# notification only, inboxes kept apart, the dead-letter path, streams no backend can change, a
# lost stream created again, an existing stream brought to its declaration, the hashes that make a
# host restart the broker, each granted consumer used by its owner and by no other backend, and the
# names and filters nobody was given.
#
#   bash compose/tests/nats-permissions.sh
#   bash compose/tests/nats-permissions.sh --inventory-only  # static grants and hashes, no Docker
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
organization EVENTS organization-service__project-seat-entitlement evt.subscription.changed.v1 billing identity
billing EVENTS billing-service__register-organization evt.organization.created.v1 organization identity
billing EVENTS billing-service__record-member-joined evt.member.joined.v1 organization identity
billing EVENTS billing-service__record-member-role-changed evt.member.role-changed.v1 organization identity
billing EVENTS billing-service__record-member-removed evt.member.removed.v1 organization identity
billing EVENTS billing-service__record-file-uploaded evt.file.uploaded.v1 storage identity
billing EVENTS billing-service__record-file-deleted evt.file.deleted.v1 storage identity
task EVENTS task-service__verify-intake-attachment evt.intake.attachment-verified.v1 storage identity
task EVENTS task-service__decide-notification-delivery-authorization evt.notification.delivery-authorization-requested.v1 notification identity
storage EVENTS storage-service__record-task-purge evt.task.purged.v1 task identity
storage EVENTS storage-service__apply-storage-byte-entitlement evt.subscription.changed.v1 billing identity
storage EVENTS storage-service__claim-intake-attachment evt.intake.attachment-claimed.v1 task identity
storage EVENTS storage-service__release-intake-attachment evt.intake.attachment-released.v1 task identity
storage EVENTS storage-service__apply-avatar-change evt.user.avatar-changed.v1 identity organization
storage EVENTS storage-service__abandon-avatar-upload evt.user.avatar-upload-abandoned.v1 identity organization
storage EVENTS storage-service__delete-avatar-owner evt.user.deleted.v1 identity organization
storage EVENTS storage-service__apply-organization-logo-change evt.organization.logo-changed.v1 organization identity
storage EVENTS storage-service__abandon-organization-logo-upload evt.organization.logo-upload-abandoned.v1 organization identity
notification EVENTS notification-service__activity-task-delivery-authorized evt.task.notification-delivery-authorized.v1 task identity
notification EVENTS notification-service__inbox-task-delivery-authorized evt.task.notification-delivery-authorized.v1 task identity
notification EVENTS notification-service__inbox-task-assigned evt.task.assigned.v1 task identity
notification EVENTS notification-service__inbox-task-status-changed evt.task.status-changed.v1 task identity
notification EVENTS notification-service__inbox-comment-created evt.comment.created.v1 task identity
notification EVENTS notification-service__inbox-comment-updated evt.comment.updated.v1 task identity
notification EVENTS notification-service__inbox-description-mentions-changed evt.task.description-mentions-changed.v1 task identity
notification EVENTS notification-service__inbox-approval-requested evt.approval.requested.v1 task identity
notification EVENTS notification-service__inbox-approval-decided evt.approval.decided.v1 task identity
notification EVENTS notification-service__inbox-task-access-requested evt.task.access-requested.v1 task identity
notification EVENTS notification-service__inbox-task-access-approved evt.task.access-request-decided.v1 task identity
notification EVENTS notification-service__notify-quota-threshold evt.quota.threshold-reached.v1 billing identity
notification EVENTS notification-service__reminder-task-delivery-authorized evt.task.notification-delivery-authorized.v1 task identity
automation EVENTS automation-service__run-task-created-rules evt.task.created.v1 task identity
automation EVENTS automation-service__run-task-status-changed-rules evt.task.status-changed.v1 task identity
integration EVENTS integration-service__purge-task-git-links evt.task.purged.v1 task identity
search EVENTS search-service__index-task-created-v1 evt.task.created.v1 task identity
search EVENTS search-service__index-task-updated-v1 evt.task.updated.v1 task identity
search EVENTS search-service__index-task-archived-v1 evt.task.archived.v1 task identity
search EVENTS search-service__index-task-unarchived-v1 evt.task.unarchived.v1 task identity
search EVENTS search-service__index-task-trashed-v1 evt.task.trashed.v1 task identity
search EVENTS search-service__index-task-restored-v1 evt.task.restored.v1 task identity
search EVENTS search-service__index-task-purged-v1 evt.task.purged.v1 task identity
search EVENTS search-service__index-task-watcher-changed-v1 evt.task.watcher-changed.v1 task identity
search EVENTS search-service__index-comment-created-v1 evt.comment.created.v1 task identity
search EVENTS search-service__index-comment-updated-v1 evt.comment.updated.v1 task identity
search EVENTS search-service__index-comment-deleted-v1 evt.comment.deleted.v1 task identity
search EVENTS search-service__index-list-created-v1 evt.list.created.v1 task identity
search EVENTS search-service__index-list-updated-v1 evt.list.updated.v1 task identity
search EVENTS search-service__index-list-archived-v1 evt.list.archived.v1 task identity
search EVENTS search-service__index-list-unarchived-v1 evt.list.unarchived.v1 task identity
search EVENTS search-service__index-list-deleted-v1 evt.list.deleted.v1 task identity
search EVENTS search-service__index-list-restored-v1 evt.list.restored.v1 task identity
search EVENTS search-service__index-list-access-changed-v1 evt.list.access-changed.v1 task identity
search EVENTS search-service__index-space-created-v1 evt.space.created.v1 task identity
search EVENTS search-service__index-space-updated-v1 evt.space.updated.v1 task identity
search EVENTS search-service__index-space-deleted-v1 evt.space.deleted.v1 task identity
search EVENTS search-service__index-space-restored-v1 evt.space.restored.v1 task identity
search EVENTS search-service__index-space-access-changed-v1 evt.space.access-changed.v1 task identity
search EVENTS search-service__index-space-access-republished-v1 evt.space.access-republished.v1 task identity
search EVENTS search-service__index-doc-created-v1 evt.doc.created.v1 document identity
search EVENTS search-service__index-doc-updated-v1 evt.doc.updated.v1 document identity
search EVENTS search-service__index-doc-deleted-v1 evt.doc.deleted.v1 document identity
search EVENTS search-service__index-file-uploaded-v1 evt.file.uploaded.v1 storage identity
search EVENTS search-service__index-file-deleted-v1 evt.file.deleted.v1 storage identity
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
realtime-gateway EVENTS realtime-gateway__relay-session-revoked evt.session.revoked.v1 identity organization
realtime-gateway EVENTS realtime-gateway__relay-session-organization-changed evt.session.organization-changed.v1 identity task
realtime-gateway EVENTS realtime-gateway__relay-member-removed evt.member.removed.v1 organization notification
realtime-gateway EVENTS realtime-gateway__relay-member-role-changed evt.member.role-changed.v1 organization search
realtime-gateway EVENTS realtime-gateway__relay-space-updated evt.space.updated.v1 task api-gateway
realtime-gateway EVENTS realtime-gateway__relay-space-access-changed evt.space.access-changed.v1 task billing
realtime-gateway EVENTS realtime-gateway__relay-space-access-republished evt.space.access-republished.v1 task document
realtime-gateway EVENTS realtime-gateway__relay-space-deleted evt.space.deleted.v1 task storage
realtime-gateway EVENTS realtime-gateway__relay-list-access-changed evt.list.access-changed.v1 task automation
realtime-gateway EVENTS realtime-gateway__relay-list-deleted evt.list.deleted.v1 task integration
realtime-gateway EVENTS realtime-gateway__relay-task-created evt.task.created.v1 task identity
realtime-gateway EVENTS realtime-gateway__relay-task-archived evt.task.archived.v1 task identity
realtime-gateway EVENTS realtime-gateway__relay-task-unarchived evt.task.unarchived.v1 task identity
realtime-gateway EVENTS realtime-gateway__relay-task-restored evt.task.restored.v1 task identity
realtime-gateway EVENTS realtime-gateway__relay-task-trashed-list evt.task.trashed.v1 task document
realtime-gateway EVENTS realtime-gateway__relay-task-moved-list evt.task.updated.v1 task storage
realtime-gateway EVENTS realtime-gateway__relay-task-trashed evt.task.trashed.v1 task identity
realtime-gateway EVENTS realtime-gateway__relay-task-purged evt.task.purged.v1 task organization
realtime-gateway EVENTS realtime-gateway__relay-task-updated evt.task.updated.v1 task notification
realtime-gateway EVENTS realtime-gateway__relay-task-status-changed evt.task.status-changed.v1 task search
realtime-gateway EVENTS realtime-gateway__relay-comment-created evt.comment.created.v1 task api-gateway
realtime-gateway EVENTS realtime-gateway__relay-git-branch-created evt.git.branch-created.v1 integration billing
realtime-gateway EVENTS realtime-gateway__relay-git-pr-opened evt.git.pr-opened.v1 integration document
realtime-gateway EVENTS realtime-gateway__relay-git-pr-merged evt.git.pr-merged.v1 integration storage
realtime-gateway EVENTS realtime-gateway__relay-git-pr-closed evt.git.pr-closed.v1 integration automation
realtime-gateway EVENTS realtime-gateway__relay-git-checks-completed evt.git.checks-completed.v1 integration identity
realtime-gateway EVENTS realtime-gateway__relay-notification-created evt.notification.created.v1 notification organization
realtime-gateway EVENTS realtime-gateway__relay-reminder-due evt.reminder.due.v1 notification task
'
# What `nats consumer next` prints of a delivery: the attempt, the consumer and stream sequences.
readonly DELIVERY='tries: ([0-9]+) / cons seq: ([0-9]+) / str seq: ([0-9]+)'
# The system subjects a backend may have besides those of its consumers: the start-up checks of
# @cadenway/nest-messaging, for notification alone the reads and advisories of the dead-letter
# worker, and for each latch owner alone the information of its latch stream.
readonly STREAM_INFO='^publish \$JS\.API\.(INFO|STREAM\.NAMES|STREAM\.INFO\.(EVENTS|EVENTS_RESTRICTED|EVENTS_DLQ))$'
readonly REALTIME_LATCH_INFO='^publish \$JS\.API\.STREAM\.INFO\.REALTIME_AUTHORIZATION_ADVISORIES$'
readonly SEARCH_LATCH_INFO='^publish \$JS\.API\.STREAM\.INFO\.SEARCH_REBUILD_ADVISORIES$'
readonly BILLING_LATCH_INFO='^publish \$JS\.API\.STREAM\.INFO\.BILLING_REBUILD_ADVISORIES$'
# The authorization invalidation durables of realtime-gateway, whose terminal advisories its latch
# stream captures; the other consumers of the gateway are not part of it.
readonly REALTIME_INVALIDATIONS='relay-session-revoked relay-session-organization-changed
relay-member-removed relay-member-role-changed relay-space-updated relay-space-access-changed
relay-space-access-republished relay-space-deleted relay-list-access-changed relay-list-deleted
relay-task-trashed relay-task-purged relay-task-updated'
# The independent consumer inventory above names every monitored Search and Billing durable.
SEARCH_DURABLES=$(awk '$1 == "search" && $3 ~ /^search-service__index-/ { print $3 }' \
  <<<"$CONSUMERS")
BILLING_DURABLES=$(awk '$1 == "billing" &&
  $3 ~ /^billing-service__(register-organization|record-)/ { print $3 }' <<<"$CONSUMERS")
REALTIME_DURABLES=$(for handler in $REALTIME_INVALIDATIONS; do
  echo "realtime-gateway__$handler"
done)
readonly SEARCH_DURABLES BILLING_DURABLES REALTIME_DURABLES
readonly CONSUMER_API='^publish \$JS\.(API\.CONSUMER\.(CREATE|INFO|MSG\.NEXT)|ACK)\.'
readonly DEAD_LETTER_READ='^publish \$JS\.API\.STREAM\.MSG\.GET\.(EVENTS|EVENTS_RESTRICTED)$'
readonly DEAD_LETTER_ADVISORY='^subscribe \$JS\.EVENT\.ADVISORY\.CONSUMER\.(MAX_DELIVERIES|MSG_TERMINATED)\.(EVENTS|EVENTS_RESTRICTED)\.>$'

compose() { docker compose -p "$PROJECT" --env-file .env.example -f infra.yaml "$@"; }
cleanup() { compose down --volumes --remove-orphans >/dev/null 2>&1 || true; }

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

# Checks the fields and exact subjects required by isEmptyConsumerAdvisoryStream.
# Arguments: title, stream and complete durable names.
check_latch() {
  OUT=$(stream_field "$2" '.config | [.storage, .retention, .discard,
    .max_msgs, .max_age, .max_bytes, .max_msg_size, .max_msgs_per_subject, (.sealed // false),
    (.deny_delete // false), (.discard_new_per_subject // false), (.allow_msg_ttl // false),
    (.allow_msg_schedules // false), (.allow_rollup_hdrs // false), (.mirror == null),
    ((.sources // []) | length), (.subject_transform == null), (.republish == null)]
    | map(tostring) | join(" ")')
  check "$1 keeps one message, with no age or size limit, and nothing else" \
    '[[ $OUT == "file limits old 1 0 -1 -1 -1 false false false false false false true 0 true true" ]]'
  EXPECTED=$(for durable in $3; do
    for kind in MAX_DELIVERIES MSG_TERMINATED; do
      echo "\$JS.EVENT.ADVISORY.CONSUMER.$kind.EVENTS.$durable"
    done
  done | sort)
  OUT=$(stream_field "$2" '.config.subjects[]' | sort)
  check "$1 captures the terminal advisories of the declared durables only" \
    '[[ $OUT == "$EXPECTED" ]]'
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
declare -A GRANT_SET=() CREATE_SET=()
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
    GRANT_SET["$user $subject"]=1
    stem=$subject
    [[ $stem == '$JS.ACK.'* ]] && stem=${stem%.>}
    [[ $stem == *[*\>]* ]] && OUT+=" $user:$subject"
    if [[ $subject =~ ^\$JS\.API\.CONSUMER\.CREATE\.([^.]+)\.([^.]+)\.(.+)$ ]]; then
      CREATES+=("$user ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}")
      CREATE_SET["$user ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"]=1
    fi
  elif [[ $user == notification && ("$right $subject" =~ $DEAD_LETTER_READ ||
    "$right $subject" =~ $DEAD_LETTER_ADVISORY) ]]; then
    continue
  elif [[ $user == realtime-gateway && "$right $subject" =~ $REALTIME_LATCH_INFO ]]; then
    continue
  elif [[ $user == search && "$right $subject" =~ $SEARCH_LATCH_INFO ]] ||
    [[ $user == billing && "$right $subject" =~ $BILLING_LATCH_INFO ]]; then
    continue
  else
    OUT+=" $user:$subject"
  fi
done
check 'no backend has a system subject beyond its consumers, its streams, the dead letters and the latch' \
  '[[ ${#GRANTS[@]} -gt 0 && -z $OUT ]]'
EXPECTED=$(sed '/^$/d' <<<"$CONSUMERS" | cut -d ' ' -f 1-4 | sort)
OUT=$(printf '%s\n' "${CREATES[@]}" | sort)
check 'the consumers of nats-server.conf are the ones this test covers' '[[ $OUT == "$EXPECTED" ]]'
OUT=''
for row in "${CREATES[@]}"; do
  read -r user stream consumer _ <<<"$row"
  for subject in "\$JS.API.CONSUMER.INFO.$stream.$consumer" \
    "\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer" "\$JS.ACK.$stream.$consumer.>"; do
    [[ ${GRANT_SET["$user $subject"]+present} ]] || OUT+=" $user:$subject"
  done
  [[ $consumer == "$user-service__"* || $consumer == "${user}__"* ]] || OUT+=" $user:$consumer"
done
check 'each has its four subjects, granted to the service its name starts with' '[[ -z $OUT ]]'
OUT=$(printf '%s\n' "${CREATES[@]}" | awk '$2 == "EVENTS_RESTRICTED" && $1 != "notification"')
check 'only notification has a consumer on EVENTS_RESTRICTED (decision D7)' '[[ -z $OUT ]]'
OUT=''
for handler in $REALTIME_INVALIDATIONS; do
  [[ ${CREATE_SET["realtime-gateway EVENTS realtime-gateway__$handler"]+present} ]] || OUT+=" $handler"
done
check 'each durable the realtime latch watches is a granted consumer of the gateway' '[[ -z $OUT ]]'
for owner in search billing; do
  OUT=''
  if [[ $owner == search ]]; then
    durables=$SEARCH_DURABLES count=29
  else
    durables=$BILLING_DURABLES count=6
  fi
  actual=0
  for durable in $durables; do
    ((actual+=1))
    [[ ${CREATE_SET["$owner EVENTS $durable"]+present} ]] || OUT+=" $durable"
  done
  check "each $owner latch durable is a granted consumer of its owner" \
    '[[ -z $OUT && $actual == "$count" ]]'
done
OUT=$((${#CONSUMER_GRANTS[@]} - 4 * ${#CREATES[@]}))
check 'and no user has any other consumer or acknowledgement subject' '[[ $OUT == 0 ]]'

if [[ ${1:-} == --inventory-only ]]; then
  exit "$FAILED"
fi
if [[ $# -ne 0 ]]; then
  echo 'usage: nats-permissions.sh [--inventory-only]' >&2
  exit 2
fi
trap cleanup EXIT
cleanup
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
check_latch 'the realtime latch, as created,' REALTIME_AUTHORIZATION_ADVISORIES "$REALTIME_DURABLES"
check_latch 'the search latch, as created,' SEARCH_REBUILD_ADVISORIES "$SEARCH_DURABLES"
check_latch 'the billing latch, as created,' BILLING_REBUILD_ADVISORIES "$BILLING_DURABLES"
OUT=$(stream_field REALTIME_AUTHORIZATION_ADVISORIES '.state.messages')
check 'and starts empty' '[[ $OUT == 0 ]]'
OUT=$(as realtime-gateway request '$JS.API.STREAM.INFO.REALTIME_AUTHORIZATION_ADVISORIES' '')
check 'the realtime gateway reads its information' \
  '[[ $OUT != *"$REFUSED"* && $OUT == *"\"name\":\"REALTIME_AUTHORIZATION_ADVISORIES\""* ]]'
OUT=$(as task request '$JS.API.STREAM.INFO.REALTIME_AUTHORIZATION_ADVISORIES' '')
check 'no other backend does' '[[ $OUT == *"$REFUSED for Publish"* ]]'
OUT=$(as realtime-gateway stream purge REALTIME_AUTHORIZATION_ADVISORIES --force)
check 'nor does the gateway clear it: an operator does' '[[ $OUT == *"$REFUSED for Publish"* ]]'

for spec in 'search SEARCH_REBUILD_ADVISORIES' 'billing BILLING_REBUILD_ADVISORIES'; do
  read -r owner latch <<<"$spec"
  OUT=$(stream_field "$latch" '.state.messages')
  check "$latch starts empty" '[[ $OUT == 0 ]]'
  OUT=$(as "$owner" request "\$JS.API.STREAM.INFO.$latch" '')
  check "$owner reads its latch information" \
    '[[ $OUT != *"$REFUSED"* && $OUT == *"\"name\":\"$latch\""* ]]'
  OUT=$(as task request "\$JS.API.STREAM.INFO.$latch" '')
  check "another backend cannot read $latch" '[[ $OUT == *"$REFUSED for Publish"* ]]'
  OUT=$(as "$owner" stream purge "$latch" --force)
  check "$owner cannot purge $latch" '[[ $OUT == *"$REFUSED for Publish"* ]]'
  OUT=$(as "$owner" stream rm "$latch" --force)
  check "$owner cannot delete $latch" '[[ $OUT == *"$REFUSED for Publish"* ]]'
done

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
check_latch 'the realtime latch, edited at each start,' REALTIME_AUTHORIZATION_ADVISORIES \
  "$REALTIME_DURABLES"
check_latch 'the search latch, edited at each start,' SEARCH_REBUILD_ADVISORIES "$SEARCH_DURABLES"
check_latch 'the billing latch, edited at each start,' BILLING_REBUILD_ADVISORIES \
  "$BILLING_DURABLES"

echo '=== 12. each granted consumer works for its owner, and for no other backend'
# Earlier sections publish and acknowledge messages, but limits retention keeps them in the stream.
# Start from an empty stream so per-filter counts cover exactly the publications in this loop.
# The restricted-code durable remains: purging removes its acknowledged message, not the consumer.
for stream in EVENTS EVENTS_RESTRICTED; do
  compose exec -T nats-streams nats stream purge "$stream" --force >/dev/null 2>&1
  OUT=$(stream_field "$stream" '.state.messages')
  check "$stream has no earlier test messages" '[[ $OUT == 0 ]]'
  if [[ $OUT != 0 ]]; then exit 1; fi
done

# Each row uses one exec, with the same NATS requests and refusals as the individual checks.
# Separate durable consumers see every retained publication of their filter, so count per filter.
mapfile -t ROWS < <(sed '/^$/d' <<<"$CONSUMERS")
declare -A SENT=()
for row in "${ROWS[@]}"; do
  read -r owner stream consumer filter publisher other <<<"$row"
  SENT[$filter]=$((${SENT[$filter]:-0} + 1))
  pending=${SENT[$filter]}
  left=$((pending - 1))
  if ! compose exec -T nats-streams sh -s -- \
    "$owner" "$stream" "$consumer" "$filter" "$publisher" "$other" "$pending" "$left" <<'SH'
owner=$1 stream=$2 consumer=$3 filter=$4 publisher=$5 other=$6 pending=$7 left=$8
failed=0
create="\$JS.API.CONSUMER.CREATE.$stream.$consumer.$filter"
info="\$JS.API.CONSUMER.INFO.$stream.$consumer"
next="\$JS.API.CONSUMER.MSG.NEXT.$stream.$consumer"
delete="\$JS.API.CONSUMER.DELETE.$stream.$consumer"
config=$(printf '{"stream_name":"%s","action":"create","config":{"name":"%s","durable_name":"%s","filter_subject":"%s","ack_policy":"explicit","deliver_policy":"all","max_deliver":5,"ack_wait":30000000000}}' "$stream" "$consumer" "$consumer" "$filter")
as_user() {
  user=$1
  shift
  password=$(printf '%s' "$user" | tr -d '-')
  nats --user "$user" --password "$password" --inbox-prefix "_INBOX.$user" --timeout 1s "$@" 2>&1 || :
}
result() {
  if [ "$1" = true ]; then
    printf 'PASS %s\n' "$2"
  else
    printf 'FAIL %s\n' "$2"
    printf '%s\n' "$out" | tail -5
    failed=1
  fi
}
contains() { case "$out" in *"$1"*) true;; *) false;; esac; }
refused() { contains "Permissions Violation for Publish to \"$1\""; }
number_field() {
  case "$out" in
    *"\"$1\":$2,"*|*"\"$1\":$2}"*|*"\"$1\": $2,"*|*"\"$1\": $2}"*) true;;
    *) false;;
  esac
}

out=$(as_user "$publisher" request "$filter" "{\"event\":\"$filter\"}")
result "$(contains "\"stream\":\"$stream\"" && echo true || echo false)" "$publisher publishes $filter"
out=$(as_user "$owner" request "$filter" '{}')
result "$(refused "$filter" && echo true || echo false)" "$owner cannot publish it"
out=$(as_user "$other" request "$create" "$config")
result "$(refused "$create" && echo true || echo false)" "$other cannot create $consumer"
out=$(as_user "$owner" request "$create" "$config")
result "$(contains "\"name\":\"$consumer\"" && number_field num_pending "$pending" && ! contains '"error"' && echo true || echo false)" "$owner creates it, or aligns it"
out=$(as_user "$other" request "$info" '')
result "$(refused "$info" && ! contains '"num_pending"' && echo true || echo false)" "$other cannot read it"
out=$(as_user "$other" request "$next" '{"batch":1,"expires":500000000}')
result "$(refused "$next" && ! contains '"event"' && echo true || echo false)" "$other cannot pull from it"
out=$(as_user "$owner" consumer next "$stream" "$consumer" --count 1 --no-ack)
result "$(contains "{\"event\":\"$filter\"}" && echo true || echo false)" "$owner pulls $filter from it"
# The delivery output gives attempt, consumer sequence and stream sequence, in that order.
sequences=$(printf '%s\n' "$out" | sed -nE 's/.*tries: ([0-9]+) \/ cons seq: ([0-9]+) \/ str seq: ([0-9]+).*/\1 \2 \3/p')
ack="\$JS.ACK.$stream.$consumer.unknown"
if [ -n "$sequences" ]; then
  set -- $sequences
  ack="\$JS.ACK.$stream.$consumer.$1.$3.$2.0.0"
fi
out=$(as_user "$other" pub "$ack" '+ACK')
result "$(refused "$ack" && echo true || echo false)" "$other cannot acknowledge on it"
out=$(as_user "$owner" consumer info "$stream" "$consumer" --json)
result "$(contains '"num_ack_pending": 1' && echo true || echo false)" 'the message is still held by the owner'
out=$(as_user "$owner" pub "$ack" '+ACK')
out="$out$(as_user "$owner" consumer info "$stream" "$consumer" --json)"
result "$( ! contains 'Permissions Violation' && contains '"num_ack_pending": 0' && number_field num_pending "$left" && echo true || echo false)" "$owner acknowledges it"
out=$(as_user "$other" request "$delete" '')
result "$(refused "$delete" && echo true || echo false)" "$other cannot delete it"
out=$(nats consumer info "$stream" "$consumer" --json 2>&1 || :)
result "$(contains "\"filter_subject\": \"$filter\"" && echo true || echo false)" 'which is still there, on its filter'
exit "$failed"
SH
  then
    FAILED=1
  fi
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
# A terminated authorization invalidation is latched until an operator clears it.
revoked=realtime-gateway__relay-session-revoked
as identity request evt.session.revoked.v1 '{"event":"terminated"}' >/dev/null
OUT=$(as realtime-gateway consumer next EVENTS "$revoked" --count 1 --no-ack)
term="\$JS.ACK.EVENTS.$revoked.unknown"
if [[ $OUT =~ $DELIVERY ]]; then
  term="\$JS.ACK.EVENTS.$revoked.${BASH_REMATCH[1]}.${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.0.0"
fi
OUT=$(as realtime-gateway pub "$term" '+TERM')
OUT=$OUT$(wait_for REALTIME_AUTHORIZATION_ADVISORIES '.state.messages' 1)
check 'a message the gateway terminates on an invalidation durable is latched' \
  '[[ $OUT != *"$REFUSED"* && $OUT == *1 ]]'
compose exec -T nats-streams nats stream purge REALTIME_AUTHORIZATION_ADVISORIES --force \
  >/dev/null 2>&1
OUT=$(stream_field REALTIME_AUTHORIZATION_ADVISORIES '.state.messages')
check 'and an operator clears the latch from the nats-streams container' '[[ $OUT == 0 ]]'
# Lost once the gateway has its consumers, the latch comes back closed, not empty.
compose exec -T nats-streams sh -c 'nats stream rm REALTIME_AUTHORIZATION_ADVISORIES --force &&
  nats stream rm SEARCH_REBUILD_ADVISORIES --force' >/dev/null 2>&1
# Within the check interval of nats-streams, a minute, as for the stream of section 10.
for _ in $(seq 1 45); do
  OUT=$(stream_field REALTIME_AUTHORIZATION_ADVISORIES '.state.messages')
  [[ $OUT == 1 ]] && break
  sleep 2
done
check 'a latch lost while the gateway consumes is created again closed, holding a marker' \
  '[[ $OUT == 1 ]]'
check_latch 'the latch created again' REALTIME_AUTHORIZATION_ADVISORIES "$REALTIME_DURABLES"
OUT=$(wait_for SEARCH_REBUILD_ADVISORIES '.state.messages' 1)
check 'the search latch lost while consuming is created again closed' '[[ $OUT == 1 ]]'
check_latch 'the search latch created again' SEARCH_REBUILD_ADVISORIES "$SEARCH_DURABLES"
# A recreation stopped after the add and before the marker leaves the latch empty in its
# initializing configuration (two messages), which no service trusts; the next pass finishes it.
compose exec -T nats-streams sh -c 'nats stream purge SEARCH_REBUILD_ADVISORIES --force &&
  nats stream edit SEARCH_REBUILD_ADVISORIES --max-msgs=2 --force' >/dev/null 2>&1
LATCH_STATE='[.config.max_msgs, .state.messages] | map(tostring) | join(" ")'
OUT=$(stream_field SEARCH_REBUILD_ADVISORIES "$LATCH_STATE")
check 'an interrupted recreation leaves the latch in a configuration no service trusts' \
  '[[ $OUT == "2 0" ]]'
for _ in $(seq 1 45); do
  OUT=$(stream_field SEARCH_REBUILD_ADVISORIES "$LATCH_STATE")
  [[ $OUT == '1 1' ]] && break
  sleep 2
done
check 'the next pass finishes it closed, holding a marker, not empty' '[[ $OUT == "1 1" ]]'
# A subject a live latch watches but no durable declares any more (a handler removed: the new
# script restarts nats-streams) is never dropped in place: that start creates the latch again,
# with a new creation time, closed while its service consumes.
before=$(stream_field SEARCH_REBUILD_ADVISORIES '.created')
retired='$JS.EVENT.ADVISORY.CONSUMER.MSG_TERMINATED.EVENTS.search-service__index-retired'
compose exec -T nats-streams sh -c 'subjects=$(nats stream info SEARCH_REBUILD_ADVISORIES --json |
  jq -r ".config.subjects | join(\",\")") &&
  nats stream edit SEARCH_REBUILD_ADVISORIES --force --subjects "$subjects,$1"' sh "$retired" \
  >/dev/null 2>&1
OUT=$(stream_field SEARCH_REBUILD_ADVISORIES '.config.subjects | length')
check 'a live latch can be left watching a durable nobody declares' \
  '[[ $OUT == $((2 * $(wc -w <<<"$SEARCH_DURABLES") + 1)) ]]'
compose restart nats-streams >/dev/null 2>&1
for _ in $(seq 1 45); do
  OUT=$(stream_field SEARCH_REBUILD_ADVISORIES '.created')
  [[ $OUT != "$before" && -n $OUT ]] && break
  sleep 2
done
check 'the start creates that latch again instead of dropping the subject' \
  '[[ $OUT != "$before" && -n $OUT ]]'
check_latch 'the latch created for a retired durable' SEARCH_REBUILD_ADVISORIES "$SEARCH_DURABLES"
OUT=$(wait_for SEARCH_REBUILD_ADVISORIES "$LATCH_STATE" '1 1')
check 'closed, holding a marker' '[[ $OUT == "1 1" ]]'
compose exec -T nats-streams nats stream purge REALTIME_AUTHORIZATION_ADVISORIES --force \
  >/dev/null 2>&1
OUT=$(stream_field REALTIME_AUTHORIZATION_ADVISORIES '.state.messages')
check 'which an operator clears in the same way' '[[ $OUT == 0 ]]'
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
