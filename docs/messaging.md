# NATS: users, subjects and streams

[Documentation index](README.md) · [Environments](../environments/README.md) · [Deployment](deployment.md)

One NATS server with JetStream per environment (`compose/infra.yaml`). The services reach it
through `@cadenway/nest-messaging`; the conventions of the events themselves (names, consumers,
retries) belong to cadenway-service-kit. This page is what the broker enforces.

## Users

`compose/nats/nats-server.conf` declares one user per backend. A connection without a user is
refused.

| User               | Backend                   | Publishes                                                                                                                 | Consumes ([consumers](#consumers))               |
| ------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `identity`         | identity-service          | `evt.user.>`, `evt.session.>`, `evt.api-token.>`, `restricted.>`                                                          | three consumers on `EVENTS`                      |
| `organization`     | organization-service      | `evt.organization.>`, `evt.member.>`, `evt.invitation.>`, `evt.domain.>`                                                  | six consumers on `EVENTS`                        |
| `billing`          | billing-service           | `evt.subscription.>`, `evt.quota.>`, `evt.invoice.>`                                                                      | nothing yet                                      |
| `task`             | task-service              | `evt.space.>`, `evt.list.>`, `evt.task.>`, `evt.comment.>`, `evt.approval.>`, `evt.milestone.>`, Intake claim and release | five consumers on `EVENTS`                       |
| `document`         | document-service          | `evt.doc.>`                                                                                                               | nothing yet                                      |
| `storage`          | storage-service           | `evt.file.>`, `evt.intake.attachment-verified.v1`                                                                         | eight consumers on `EVENTS`                      |
| `notification`     | notification-service      | `evt.notification.>`, `evt.reminder.>`, `dlq.>`                                                                           | nineteen on `EVENTS`, two on `EVENTS_RESTRICTED` |
| `automation`       | automation-service        | `evt.automation.>`                                                                                                        | nothing yet                                      |
| `integration`      | integration-service       | `evt.git.>`                                                                                                               | nothing yet                                      |
| `search`           | search-service            | nothing                                                                                                                   | nothing yet                                      |
| `api-gateway`      | API gateway               | `evt.api-usage.>`                                                                                                         | nothing                                          |
| `realtime-gateway` | realtime gateway          | nothing                                                                                                                   | fifteen on `EVENTS`                              |
| `admin`            | `nats-streams`, operators | everything                                                                                                                | everything                                       |

A subject is `evt.<event-name>`, and an event name starts with its entity: the entity decides who
may publish. The lists above are the events each service declares in its `AGENTS.md`, plus the
decisions of the integration plan: `api-usage.recorded` for the gateway, and `invitation.issued`
for organization-service, which sends the invitation e-mail through notification-service. The
plan also keeps invitation events off the restricted stream: accepting an invitation requires a
session whose verified address is the invited one, so the invitation id in the e-mail link is no
secret capability.

A service connects with three variables: `NATS_URL`, `NATS_USER` (the user above) and
`NATS_PASSWORD`. Its definition takes the password from `<NAME>_NATS_PASSWORD` (`TASK_NATS_PASSWORD`,
`API_GATEWAY_NATS_PASSWORD`).

**The client must use the inbox prefix `_INBOX.<user>`.** A user may only subscribe under its own
prefix, so that no backend can listen to the replies, and therefore to the messages, another one
receives. A client left on the default `_INBOX.>` prefix is refused its first request.

## Reading events

Events are read through JetStream consumers, never through a plain subscription: no backend may
subscribe to `evt.>`. A backend reads through the [consumers](#consumers) granted to it, each by
its exact name and filter: it reads only the events those consumers filter. The one exception is
the [dead-letter worker](#dead-letters) of notification-service, which reads any message of
`EVENTS` and `EVENTS_RESTRICTED` by its sequence.

`@cadenway/nest-messaging` gives each handler a durable pull consumer named `<service>__<handler>`
that filters one event, and uses four API subjects on it. Each is granted to the user that owns
the consumer, for that consumer only:

| Step                                             | Subject                                                                     |
| ------------------------------------------------ | --------------------------------------------------------------------------- |
| Create the consumer, or align its settings       | `$JS.API.CONSUMER.CREATE.<stream>.<consumer>.<filter>`                      |
| Read the consumer                                | `$JS.API.CONSUMER.INFO.<stream>.<consumer>`                                 |
| Pull messages                                    | `$JS.API.CONSUMER.MSG.NEXT.<stream>.<consumer>`, replies on `_INBOX.<user>` |
| Acknowledge, ask for a later retry, or terminate | `$JS.ACK.<stream>.<consumer>.>`                                             |

No wildcard stands for a stream, a consumer or a filter. The last `>` covers only the delivery
counters the server appends to the reply subject of a message. Therefore:

- A backend cannot create, read, pull from, acknowledge on or change the consumer of another one:
  it cannot take the messages of another backend, nor refilter its consumer.
- It cannot open a consumer under a name it was not given: a new handler waits for its grant (see
  [adding a consumer](#adding-a-consumer)).
- It cannot give its own consumer another filter. The filter is part of the granted create
  subject, and the server refuses a create whose body filters another subject or names another
  consumer. The kit would refuse to run the handler on such a consumer anyway: a handler consumes
  exactly one event.
- No backend may delete a consumer, its own included. `@cadenway/nest-messaging` never deletes
  one; an operator removes an obsolete one with the `admin` user.

The kit uses no other consumer subject: no list of the consumers, and not the older
`$JS.API.CONSUMER.DURABLE.CREATE`, which carries no filter and is granted to nobody. At start-up it
reads the streams it uses (`$JS.API.STREAM.INFO.<stream>`), which each user keeps for its streams.

### What a grant does not limit

A permission matches the subject of a request, not its body. Apart from the name and the filter,
which the server ties to the subject, the owner of a consumer chooses its settings, and the server
accepts a push delivery subject the owner itself may not publish on (checked against NATS 2.15.2).
A backend taken over could therefore have the events of its own consumers delivered to another
subject, such as `dlq.>` or the rebuild subject of another backend: never an event it cannot
already read, but to readers that were not meant to receive it. Closing that would take consumers
created by the platform with the `admin` user, the services keeping only the read, pull and
acknowledgement subjects (`manageConsumers: false` in `@cadenway/nest-messaging`): not done.

## Consumers

The consumers granted today, as the services declare them on their `main` branch or will in the
release that adds them (see [adding a consumer](#adding-a-consumer)):

| User               | Consumer                                                   | Stream              | Filter                                                 | Published by | For                                                                             |
| ------------------ | ---------------------------------------------------------- | ------------------- | ------------------------------------------------------ | ------------ | ------------------------------------------------------------------------------- |
| `identity`         | `identity-service__project-member-joined`                  | `EVENTS`            | `evt.member.joined.v1`                                 | organization | Its projection of the memberships, checked when a session switches organization |
| `identity`         | `identity-service__project-member-role-changed`            | `EVENTS`            | `evt.member.role-changed.v1`                           | organization | The same projection                                                             |
| `identity`         | `identity-service__project-member-removed`                 | `EVENTS`            | `evt.member.removed.v1`                                | organization | The same projection                                                             |
| `organization`     | `organization-service__project-user-signed-up`             | `EVENTS`            | `evt.user.signed-up.v1`                                | identity     | Its directory of the users: names and e-mails in the member list                |
| `organization`     | `organization-service__project-user-email-verified`        | `EVENTS`            | `evt.user.email-verified.v1`                           | identity     | The same directory                                                              |
| `organization`     | `organization-service__project-user-profile-updated`       | `EVENTS`            | `evt.user.profile-updated.v1`                          | identity     | The same directory                                                              |
| `organization`     | `organization-service__project-user-email-changed`         | `EVENTS`            | `evt.user.email-changed.v1`                            | identity     | The same directory                                                              |
| `organization`     | `organization-service__project-user-two-step`              | `EVENTS`            | `evt.user.two-step-verification-changed.v1`            | identity     | The same directory: the two-step verification column of the member list         |
| `organization`     | `organization-service__remove-deleted-user`                | `EVENTS`            | `evt.user.deleted.v1`                                  | identity     | Removing the memberships of a deleted account                                   |
| `task`             | `task-service__project-member-joined`                      | `EVENTS`            | `evt.member.joined.v1`                                 | organization | Its projection of the memberships: the roles it checks and the valid assignees  |
| `task`             | `task-service__project-member-role-changed`                | `EVENTS`            | `evt.member.role-changed.v1`                           | organization | The same projection                                                             |
| `task`             | `task-service__project-member-removed`                     | `EVENTS`            | `evt.member.removed.v1`                                | organization | The same projection, which also unassigns a removed member                      |
| `storage`          | `storage-service__record-task-purge`                       | `EVENTS`            | `evt.task.purged.v1`                                   | task         | Revokes attachment access and schedules object cleanup                          |
| `task`             | `task-service__verify-intake-attachment`                   | `EVENTS`            | `evt.intake.attachment-verified.v1`                    | storage      | Marks the applicant's reserved file verified                                    |
| `storage`          | `storage-service__claim-intake-attachment`                 | `EVENTS`            | `evt.intake.attachment-claimed.v1`                     | task         | Adopts a verified file after the task and claim commit                          |
| `storage`          | `storage-service__release-intake-attachment`               | `EVENTS`            | `evt.intake.attachment-released.v1`                    | task         | Fences an unused reservation and schedules cleanup                              |
| `storage`          | `storage-service__apply-avatar-change`                     | `EVENTS`            | `evt.user.avatar-changed.v1`                           | identity     | Adopts the new avatar derivative and retires its predecessor                    |
| `storage`          | `storage-service__abandon-avatar-upload`                   | `EVENTS`            | `evt.user.avatar-upload-abandoned.v1`                  | identity     | Fences an abandoned avatar upload and schedules cleanup                         |
| `storage`          | `storage-service__delete-avatar-owner`                     | `EVENTS`            | `evt.user.deleted.v1`                                  | identity     | Retires avatar media for the deleted account                                    |
| `storage`          | `storage-service__apply-organization-logo-change`          | `EVENTS`            | `evt.organization.logo-changed.v1`                     | organization | Adopts the new logo derivative and retires its predecessor                      |
| `storage`          | `storage-service__abandon-organization-logo-upload`        | `EVENTS`            | `evt.organization.logo-upload-abandoned.v1`            | organization | Fences an abandoned logo upload and schedules cleanup                           |
| `notification`     | `notification-service__request-invitation-email`           | `EVENTS`            | `evt.invitation.issued.v1`                             | organization | The invitation e-mail                                                           |
| `notification`     | `notification-service__request-password-changed-email`     | `EVENTS`            | `evt.user.password-changed.v1`                         | identity     | The password-changed security e-mail                                            |
| `notification`     | `notification-service__request-email-changed-email`        | `EVENTS`            | `evt.user.email-changed.v1`                            | identity     | The address-changed security e-mail                                             |
| `notification`     | `notification-service__request-new-device-email`           | `EVENTS`            | `evt.session.opened-on-new-device.v1`                  | identity     | The new-device sign-in security e-mail                                          |
| `notification`     | `notification-service__request-deletion-scheduled-email`   | `EVENTS`            | `evt.user.deletion-scheduled.v1`                       | identity     | The deletion-scheduled security e-mail                                          |
| `notification`     | `notification-service__request-deletion-cancelled-email`   | `EVENTS`            | `evt.user.deletion-cancelled.v1`                       | identity     | The deletion-cancelled security e-mail                                          |
| `notification`     | `notification-service__request-two-step-email`             | `EVENTS`            | `evt.user.two-step-verification-changed.v1`            | identity     | The two-step verification security e-mail                                       |
| `notification`     | `notification-service__request-code-email`                 | `EVENTS_RESTRICTED` | `restricted.one-time-code.issued.v1`                   | identity     | The code e-mail (see [restricted events](#restricted-events))                   |
| `notification`     | `notification-service__request-password-reset-email`       | `EVENTS_RESTRICTED` | `restricted.password-reset-link.issued.v1`             | identity     | The password reset e-mail (see [restricted events](#restricted-events))         |
| `task`             | `task-service__decide-notification-delivery-authorization` | `EVENTS`            | `evt.notification.delivery-authorization-requested.v1` | notification | Resolve current Task access for one delivery attempt                            |
| `notification`     | `notification-service__inbox-task-delivery-authorized`     | `EVENTS`            | `evt.task.notification-delivery-authorized.v1`         | task         | Finish an Inbox delivery attempt                                                |
| `notification`     | `notification-service__reminder-task-delivery-authorized`  | `EVENTS`            | `evt.task.notification-delivery-authorized.v1`         | task         | Finish a reminder delivery attempt                                              |
| `notification`     | `notification-service__activity-task-delivery-authorized`  | `EVENTS`            | `evt.task.notification-delivery-authorized.v1`         | task         | Finish an activity e-mail delivery attempt                                      |
| `notification`     | `notification-service__inbox-task-assigned`                | `EVENTS`            | `evt.task.assigned.v1`                                 | task         | Stage the assignee's Inbox delivery                                             |
| `notification`     | `notification-service__inbox-task-status-changed`          | `EVENTS`            | `evt.task.status-changed.v1`                           | task         | Stage watcher Inbox deliveries                                                  |
| `notification`     | `notification-service__inbox-comment-created`              | `EVENTS`            | `evt.comment.created.v1`                               | task         | Stage mention, reply and watcher Inbox deliveries                               |
| `notification`     | `notification-service__inbox-comment-updated`              | `EVENTS`            | `evt.comment.updated.v1`                               | task         | Stage newly mentioned recipients                                                |
| `notification`     | `notification-service__inbox-description-mentions-changed` | `EVENTS`            | `evt.task.description-mentions-changed.v1`             | task         | Stage newly mentioned recipients                                                |
| `notification`     | `notification-service__inbox-approval-requested`           | `EVENTS`            | `evt.approval.requested.v1`                            | task         | Stage approval reviewer Inbox deliveries                                        |
| `notification`     | `notification-service__inbox-approval-decided`             | `EVENTS`            | `evt.approval.decided.v1`                              | task         | Stage the approval requester's Inbox delivery                                   |
| `notification`     | `notification-service__inbox-task-access-requested`        | `EVENTS`            | `evt.task.access-requested.v1`                         | task         | Stage the owning reviewer's Inbox delivery                                      |
| `notification`     | `notification-service__inbox-task-access-approved`         | `EVENTS`            | `evt.task.access-request-decided.v1`                   | task         | Stage the requester after an approval                                           |
| `realtime-gateway` | `realtime-gateway__relay-session-revoked`                  | `EVENTS`            | `evt.session.revoked.v1`                               | identity     | Close sockets bound to the revoked session                                      |
| `realtime-gateway` | `realtime-gateway__relay-session-organization-changed`     | `EVENTS`            | `evt.session.organization-changed.v1`                  | identity     | Close sockets bound to an older session selection                               |
| `realtime-gateway` | `realtime-gateway__relay-member-role-changed`              | `EVENTS`            | `evt.member.role-changed.v1`                           | organization | Close sockets with a superseded membership role                                 |
| `realtime-gateway` | `realtime-gateway__relay-member-removed`                   | `EVENTS`            | `evt.member.removed.v1`                                | organization | Close sockets bound to the removed membership                                   |
| `realtime-gateway` | `realtime-gateway__relay-space-updated`                    | `EVENTS`            | `evt.space.updated.v1`                                 | task         | Invalidate affected space visibility                                            |
| `realtime-gateway` | `realtime-gateway__relay-space-access-changed`             | `EVENTS`            | `evt.space.access-changed.v1`                          | task         | Invalidate affected space visibility                                            |
| `realtime-gateway` | `realtime-gateway__relay-space-access-republished`         | `EVENTS`            | `evt.space.access-republished.v1`                      | task         | Invalidate affected space visibility                                            |
| `realtime-gateway` | `realtime-gateway__relay-space-deleted`                    | `EVENTS`            | `evt.space.deleted.v1`                                 | task         | Discard connections using deleted space visibility                              |
| `realtime-gateway` | `realtime-gateway__relay-list-access-changed`              | `EVENTS`            | `evt.list.access-changed.v1`                           | task         | Invalidate affected list visibility                                             |
| `realtime-gateway` | `realtime-gateway__relay-list-deleted`                     | `EVENTS`            | `evt.list.deleted.v1`                                  | task         | Discard connections using deleted list visibility                               |
| `realtime-gateway` | `realtime-gateway__relay-task-updated`                     | `EVENTS`            | `evt.task.updated.v1`                                  | task         | Relay a minimal task notice after checking current access                       |
| `realtime-gateway` | `realtime-gateway__relay-task-status-changed`              | `EVENTS`            | `evt.task.status-changed.v1`                           | task         | Relay a minimal status notice after checking current access                     |
| `realtime-gateway` | `realtime-gateway__relay-task-trashed`                     | `EVENTS`            | `evt.task.trashed.v1`                                  | task         | Remove subscriptions made stale by task trash                                   |
| `realtime-gateway` | `realtime-gateway__relay-task-purged`                      | `EVENTS`            | `evt.task.purged.v1`                                   | task         | Remove subscriptions made stale by task purge                                   |
| `realtime-gateway` | `realtime-gateway__relay-comment-created`                  | `EVENTS`            | `evt.comment.created.v1`                               | task         | Relay a minimal task notice after checking current access                       |

The other backends consume nothing yet, and keep only the stream information the kit reads at
start-up. The API gateway consumes nothing.

### Adding a consumer

A new handler is a new consumer, and its grant is a deployment prerequisite, like a new environment
variable: it is merged here and has reached an environment before the release of the service that
adds the handler runs there. A release that comes first is refused its consumer (`Permissions
Violation for Publish to "$JS.API.CONSUMER..."`), and the refusal fails its start-up.

The service repository reads what to request from its own code:

| Value                  | Where it comes from                                                                                                                                      |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<service>`            | The `service` option of its `MessagingModule` (`identity-service`)                                                                                       |
| `<handler>`            | The `handler` it gives `EventConsumers.subscribe` (`project-member-joined`)                                                                              |
| `<stream>`, `<filter>` | `EVENTS` and `evt.<event>` for the `event` it gives `subscribe`; `EVENTS_RESTRICTED` and `restricted.<event>` when its `restrictedEvents` list the event |

and asks for these four subjects on its NATS user:

```text
$JS.API.CONSUMER.CREATE.<stream>.<service>__<handler>.<filter>
$JS.API.CONSUMER.INFO.<stream>.<service>__<handler>
$JS.API.CONSUMER.MSG.NEXT.<stream>.<service>__<handler>
$JS.ACK.<stream>.<service>__<handler>.>
```

The pull request here adds them to the user in `compose/nats/nats-server.conf`, adds the consumer
to the list at the top of `compose/tests/nats-permissions.sh` (with the backend that publishes the
event and another backend that must be refused) and to the table above, and changes
`NATS_SERVER_CONF_SHA256`. The test fails when the configuration and its list differ.

The service repository adds the same four subjects to the copy of these permissions its own
development broker runs (`compose.dev.yaml`), so that its integration tests meet the refusal the
environments would. To try a handler on the local stack before its grant is merged, add the grant
to your checkout of `nats-server.conf` and recreate the broker
(`docker compose up -d --force-recreate nats`).

- Renaming a handler, or making it consume another event, makes a new consumer: it needs a new
  grant.
- A handler that is removed leaves its consumer on the broker until an operator deletes it. Its
  grant is removed once no running release uses it.

## Restricted events

The identity events that carry a single-use code or link for a security e-mail (sign-in code,
reset link) must reach notification-service only. A subscription permission alone would not keep
them private: a message stored in a stream is also read by its sequence, a right granted per
stream, which the dead-letter worker needs on every stream it copies from. They therefore live
outside `evt.>`, in a stream of their own, with its own short retention:

- subject `restricted.<event-name>`, stream `EVENTS_RESTRICTED`;
- `identity` is the only user that publishes on `restricted.>`;
- `notification` is the only user granted a consumer on `EVENTS_RESTRICTED`, and the only one that
  may read one of its messages by sequence. Nobody may subscribe to `restricted.>`.

The contracts mark an event restricted (`RESTRICTED_EVENT_NAMES` of `@cadenway/contracts`, today
`one-time-code.issued.v1` and `password-reset-link.issued.v1`), and `@cadenway/nest-messaging`
publishes and consumes the events a service lists in `restrictedEvents` on `restricted.` and
`EVENTS_RESTRICTED` instead of `evt.` and `EVENTS`.

## Streams

| Stream              | Subjects       | Kept    | Size cap | Holds                                         |
| ------------------- | -------------- | ------- | -------- | --------------------------------------------- |
| `EVENTS`            | `evt.>`        | 7 days  | 1 GiB    | Every event                                   |
| `EVENTS_RESTRICTED` | `restricted.>` | 1 hour  | 64 MiB   | The restricted events                         |
| `EVENTS_DLQ`        | `dlq.>`        | 30 days | 256 MiB  | Messages a consumer gave up on (dead letters) |

File storage, oldest messages dropped first, duplicates of a `Nats-Msg-Id` refused for two minutes.
The sizes are starting values.

The file-backed `REALTIME_AUTHORIZATION_ADVISORIES` stream captures terminal JetStream advisories
for the Realtime authorization consumers. It retains the newest advisory without expiration.
Realtime can read the stream status and closes socket admission and existing transports when it
cannot confirm that the stream is empty.

The file-backed `SEARCH_REBUILD_ADVISORIES` stream captures `MAX_DELIVERIES` and `MSG_TERMINATED`
for the 29 exact Search indexing durables. It holds one terminal advisory without expiration.
The Search credential can read its status. Search checks the guard before and after sampling
consumer progress and refuses candidate index promotion if the guard cannot certify an empty
stream. Each source durable can pull, acknowledge and query its own state, and can subscribe
only with the exact owner event filter in the ACL.

A restricted event carries a single-use code valid ten minutes, or a link that expires as soon. One
hour delivers it through a short outage of notification-service, and none stays readable in the
stream past its use.

No backend can create, change, purge or delete a stream. The `nats-streams` container of
`compose/infra.yaml` owns them: it runs `compose/nats/ensure-streams.sh` with the `admin` user,
provisions the streams at start and checks them every minute. It recreates the three ordinary
event streams when missing. Its readiness also requires the recorded Realtime and Search
advisory stream identities to match. A changed limit reaches a
stream that exists when the container starts again, which a new `ENSURE_STREAMS_SHA256` causes on
every host (see [changing the permissions](#changing-the-permissions)); a lower age drops the
older messages at once, and the retention and storage of a stream never change.

- Locally, the services that use the broker wait for it (`depends_on` in `compose.local.yaml`).
- On a host, it is one of the infrastructure services the GitOps agent starts and waits for before
  any deployable; nothing else is needed.

The streams are not backed up: a service keeps its sent outbox rows seven days and can publish them
again, except the restricted ones. From `@cadenway/nest-messaging` 0.1.2, the statement that marks a
restricted row sent replaces its payload with a redacted envelope (`"$redacted": true`), and a
redacted row is never requeued or published again: a restricted event lost with the broker is not
restored, its owner issues a new code or link. The payload before redaction stays in the
write-ahead log, the dead row versions and the backups of PostgreSQL for as long as they keep it.

### Recover Realtime authorization

The supervisor records the authorization advisory stream's creation identity in
`nats-stream-state`, a volume separate from `nats-data`. Preserve both volumes when replacing
containers. Once provisioned, a missing or replaced stream keeps the supervisor unhealthy and the
supervisor does not automatically recreate or adopt it.

Running Realtime replicas do not read the identity volume. A compatible out-of-band replacement
could appear empty to those replicas before they are stopped. After loss of the stream, either
volume, or restoration to an earlier point, pause GitOps and ensure its current rollout has
stopped. Stop all Realtime replicas before replacing or reinitializing the stream. Reconcile Identity sessions, Organization
memberships and Task visibility while admission is closed. An older backup of the same stream can
have the original creation identity. If both volumes are lost, bootstrap cannot distinguish the
loss from initial provisioning. In either case, keep Realtime stopped until reconciliation and
verification of the invalidation backlog are complete. When the original stream cannot be
restored, reset the persisted stream identity only while the replicas are stopped, then let the
supervisor provision or adopt the repaired stream. Verify the supervisor, the invalidation
backlog and authorization sources before restarting Realtime and restoring GitOps.

When the stream retains a terminal advisory, record the observed message sequence and reconcile
the authorities while admission is closed. Delete only the observed message by sequence once
reconciliation is complete. Recheck the stream and the invalidation consumer backlog before
reopening admission. Repeat reconciliation if a newer advisory arrived during the operation.

## Dead letters

JetStream has no dead-letter queue. One worker listens to the advisories
`$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.<stream>.>` (and `MSG_TERMINATED`), reads the failed
message by its sequence and publishes a copy on `dlq.<consumer>.<subject>`.

**The worker runs in notification-service, and only there.** Reading any message by its sequence
includes the restricted ones, and notification is the only backend allowed to see them: any other
owner would widen who can read a single-use code. Notification is the only service account on the
event broker allowed to listen to the advisories, read a message of `EVENTS` or
`EVENTS_RESTRICTED` by sequence, and publish on `dlq.>`. Its worker comes from
`@cadenway/nest-messaging`.

No backend consumes `EVENTS_DLQ`. An operator reads it from the `nats-streams` container:

```bash
docker compose exec nats-streams nats stream view EVENTS_DLQ
```

### Local durable advisory capture

`compose/compose.advisories.local.yaml` adds a private NATS observer to the local infrastructure
model. The leaf user can subscribe to `MAX_DELIVERIES` and `MSG_TERMINATED` for `EVENTS` and
`EVENTS_RESTRICTED` only. The observer persists just these advisories in its own JetStream domain
and volume. The leaf listener binds to a separate Docker network shared by the two brokers.
The original three latches continue to receive the same advisory subjects on the event broker.
The hosted Compose entry point omits this overlay.

For an isolated broker project, set distinct local values for
`NATS_ADVISORY_LEAF_PASSWORD`, `NATS_ADVISORY_ADMIN_PASSWORD` and
`NATS_ADVISORY_READER_PASSWORD`. Use letters and digits, beginning with a letter. Run the command
from `compose/` with a fresh local project name to start both provisioners and their brokers.

```bash
docker compose -p cadenway-local-advisories --env-file .env.example \
  -f infra.yaml -f compose.advisories.local.yaml up -d --wait nats-streams nats-advisory-streams
```

When exercising the durable worker on that Docker network, use a second connection to
`nats://nats-advisories:4222` with reader `notification`, the advisory reader password, and the
`_INBOX.notification` prefix. Pull from `EVENTS_ADVISORIES` and
`notification-dead-letter-advisories-v1` via the observer's local JetStream API. That user can
inspect this consumer, pull and acknowledge only. The main connection still reads event payloads from
the original streams and publishes to `EVENTS_DLQ`.

The observer keeps unacknowledged advisories for up to seven days, 100,000 messages or 64 MiB.
It discards new advisories at capacity. The provisioner checks coverage of all four subjects
on the leaf connection, backlog below 90%, and the original stream and consumer identities.
It logs a capture fault and removes its readiness marker when a check fails. Loss of the stream
or consumer requires operator recovery after the first provisioning.

The backlog survives an offline worker and an observer restart with its volume intact. Native
advisories emitted before the leaf subscribes or while the observer is unreachable have no
broker replay into the observer. Brief disconnects can occur between readiness checks. An advisory
cannot restore the payload of an expired or deleted source message. Check both volumes and the
reported outage when investigating a gap.

With a local Docker context active, run `bash compose/tests/nats-advisories.sh` from the repository
root for the disposable test.

## Rebuilds

A consumer that rebuilds its state (the search index) asks the owners to re-emit theirs. These
messages are plain NATS, outside every stream: a backend may publish `rebuild.<consumer>.<entity>`
for the entities it owns, and subscribe to `rebuild.<its user>.>` only (`rebuild.search.task`).

## Changing the permissions

- A new entity: add `evt.<entity>.>` and `rebuild.*.<entity>` to the user of the backend that owns
  it. Until then its publication is refused.
- A new consumer, on `EVENTS` or `EVENTS_RESTRICTED`: its four subjects on the user of its
  backend, deployed before the release that adds the handler (see
  [adding a consumer](#adding-a-consumer)). Until then the release fails at start-up.
- A new backend: add its user, its `<NAME>_NATS_PASSWORD` to the `nats` service of
  `compose/infra.yaml`, to `compose/.env.example` and to the secrets of each environment.

The broker reads its configuration at start-up, and Compose does not recreate a container when a
mounted file changes. `NATS_SERVER_CONF_SHA256` in `compose/infra.yaml` is the hash of
`nats-server.conf`, and `ENSURE_STREAMS_SHA256` the hash of `ensure-streams.sh`: change the value
with the file (`sha256sum compose/nats/nats-server.conf`), and every environment restarts the
container. `compose/tests/nats-permissions.sh` fails when they differ.

Keep the grants and the authorization latch in place when rolling back a service image. If a
broker configuration rollback is necessary, first roll back or stop the consumers that rely on
its new grants. Observe the recorded Storage, Gateway and Task rollback floors before accepting
anonymous files or reopening purge workers.

## Secrets

`secrets.sops.env` of each environment holds `NATS_ADMIN_PASSWORD` and one `<NAME>_NATS_PASSWORD`
per backend: `IDENTITY`, `ORGANIZATION`, `BILLING`, `TASK`, `DOCUMENT`, `STORAGE`, `NOTIFICATION`,
`AUTOMATION`, `INTEGRATION`, `SEARCH`, `API_GATEWAY`, `REALTIME_GATEWAY`.

The broker parses a password as configuration. Letters and digits starting with a letter are always
safe. A number, `true`, `false` or a value with a space stops the broker at start-up; a value
starting with `$2` is taken for a bcrypt hash. A changed password restarts the broker, and the
services reconnect with theirs once their own definition is applied.

## Checks

`compose/tests/nats-permissions.sh` starts the broker of `compose/infra.yaml` as a throwaway
project and proves the above against it; CI runs it on every pull request. For the consumers, it
checks that the configuration grants exactly the consumers of its list, each with its four
subjects and nothing more; that each one works for its owner, on the subjects the kit uses; that
another backend is refused its create, read, pull, acknowledgement and deletion; and that a name or
a filter nobody was given is refused to the backend it would belong to.
