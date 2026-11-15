# NATS: users, subjects and streams

[Documentation index](README.md) · [Environments](../environments/README.md) · [Deployment](deployment.md)

One NATS server with JetStream per environment (`compose/infra.yaml`). The services reach it
through `@cadenway/nest-messaging`; the conventions of the events themselves (names, consumers,
retries) belong to cadenway-service-kit. This page is what the broker enforces.

## Users

`compose/nats/nats-server.conf` declares one user per backend. A connection without a user is
refused.

| User               | Backend                   | Publishes                                                                                       | Consumes                      |
| ------------------ | ------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------- |
| `identity`         | identity-service          | `evt.user.>`, `evt.session.>`, `evt.api-token.>`, `restricted.>`                                | `EVENTS`                      |
| `organization`     | organization-service      | `evt.organization.>`, `evt.member.>`, `evt.domain.>`                                            | `EVENTS`                      |
| `billing`          | billing-service           | `evt.subscription.>`, `evt.quota.>`, `evt.invoice.>`                                            | `EVENTS`                      |
| `task`             | task-service              | `evt.space.>`, `evt.list.>`, `evt.task.>`, `evt.comment.>`, `evt.approval.>`, `evt.milestone.>` | `EVENTS`                      |
| `document`         | document-service          | `evt.doc.>`                                                                                     | `EVENTS`                      |
| `storage`          | storage-service           | `evt.file.>`                                                                                    | `EVENTS`                      |
| `notification`     | notification-service      | `evt.notification.>`, `evt.reminder.>`, `dlq.>`                                                 | `EVENTS`, `EVENTS_RESTRICTED` |
| `automation`       | automation-service        | `evt.automation.>`                                                                              | `EVENTS`                      |
| `integration`      | integration-service       | `evt.git.>`                                                                                     | `EVENTS`                      |
| `search`           | search-service            | nothing                                                                                         | `EVENTS`                      |
| `api-gateway`      | API gateway               | `evt.api-usage.>`                                                                               | nothing                       |
| `realtime-gateway` | realtime gateway          | nothing                                                                                         | `EVENTS`                      |
| `admin`            | `nats-streams`, operators | everything                                                                                      | everything                    |

A subject is `evt.<event-name>`, and an event name starts with its entity: the entity decides who
may publish. The lists above are the events each service declares in its `AGENTS.md`, plus the
decisions of the integration plan (`api-usage.recorded` for the gateway).

A service connects with three variables: `NATS_URL`, `NATS_USER` (the user above) and
`NATS_PASSWORD`. Its definition takes the password from `<NAME>_NATS_PASSWORD` (`TASK_NATS_PASSWORD`,
`API_GATEWAY_NATS_PASSWORD`).

**The client must use the inbox prefix `_INBOX.<user>`.** A user may only subscribe under its own
prefix, so that no backend can listen to the replies, and therefore to the messages, another one
receives. A client left on the default `_INBOX.>` prefix is refused its first request.

## Reading events

Events are read through JetStream consumers, never through a plain subscription: no backend may
subscribe to `evt.>`. A user that consumes may create a consumer on `EVENTS`, read its messages
and acknowledge them, whatever the subject: every event of `EVENTS` is readable by every consuming
backend. No backend may delete a consumer; an operator removes an obsolete one with the `admin`
user.

## Restricted events

The identity events that carry a single-use code or link for a security e-mail (sign-in code,
reset link) must reach notification-service only. A subscription permission alone would not keep
them private: a message stored in a stream is read through a consumer or by its sequence, and the
name of a consumer cannot be matched by a permission. They therefore live outside `evt.>`, in a
stream of their own:

- subject `restricted.<event-name>`, stream `EVENTS_RESTRICTED`;
- `identity` is the only user that publishes on `restricted.>`;
- `notification` is the only user that may create a consumer on `EVENTS_RESTRICTED`, pull from one,
  or read one of its messages by sequence. Nobody may subscribe to `restricted.>`.

The events do not exist yet: their names are chosen in cadenway-api-contracts, and
`@cadenway/nest-messaging` has to publish an event marked as restricted on `restricted.` instead of
`evt.` and bind its consumer to `EVENTS_RESTRICTED`.

## Streams

| Stream              | Subjects       | Kept    | Size cap | Holds                                         |
| ------------------- | -------------- | ------- | -------- | --------------------------------------------- |
| `EVENTS`            | `evt.>`        | 7 days  | 1 GiB    | Every event                                   |
| `EVENTS_RESTRICTED` | `restricted.>` | 1 hour  | 64 MiB   | The restricted events                         |
| `EVENTS_DLQ`        | `dlq.>`        | 30 days | 256 MiB  | Messages a consumer gave up on (dead letters) |

File storage, oldest messages dropped first, duplicates of a `Nats-Msg-Id` refused for two minutes.
The sizes are starting values.

A restricted event carries a single-use code valid ten minutes, or a link that expires as soon. One
hour delivers it through a short outage of notification-service, and none stays readable in the
stream past its use.

No backend can create, change, purge or delete a stream. The `nats-streams` container of
`compose/infra.yaml` owns them: it runs `compose/nats/ensure-streams.sh` with the `admin` user,
creates or updates the three streams at start, then checks every minute that they exist and
creates again one the broker lost. It is healthy while the three exist. A changed limit reaches a
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

## Dead letters

JetStream has no dead-letter queue. One worker listens to the advisories
`$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.<stream>.>` (and `MSG_TERMINATED`), reads the failed
message by its sequence and publishes a copy on `dlq.<consumer>.<subject>`.

**The worker runs in notification-service, and only there.** Reading any message by its sequence
includes the restricted ones, and notification is the only backend allowed to see them: any other
owner would widen who can read a single-use code. Its user is the only one that may listen to the
advisories, read a message of `EVENTS` or `EVENTS_RESTRICTED` by sequence, and publish on `dlq.>`.
The worker is part of `@cadenway/nest-messaging`; no other backend enables it.

No backend consumes `EVENTS_DLQ`. An operator reads it from the `nats-streams` container:

```bash
docker compose exec nats-streams nats stream view EVENTS_DLQ
```

## Rebuilds

A consumer that rebuilds its state (the search index) asks the owners to re-emit theirs. These
messages are plain NATS, outside every stream: a backend may publish `rebuild.<consumer>.<entity>`
for the entities it owns, and subscribe to `rebuild.<its user>.>` only (`rebuild.search.task`).

## Changing the permissions

- A new entity: add `evt.<entity>.>` and `rebuild.*.<entity>` to the user of the backend that owns
  it. Until then its publication is refused.
- A new backend: add its user, its `<NAME>_NATS_PASSWORD` to the `nats` service of
  `compose/infra.yaml`, to `compose/.env.example` and to the secrets of each environment.

The broker reads its configuration at start-up, and Compose does not recreate a container when a
mounted file changes. `NATS_SERVER_CONF_SHA256` in `compose/infra.yaml` is the hash of
`nats-server.conf`, and `ENSURE_STREAMS_SHA256` the hash of `ensure-streams.sh`: change the value
with the file (`sha256sum compose/nats/nats-server.conf`), and every environment restarts the
container. `compose/tests/nats-permissions.sh` fails when they differ.

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
project and proves the above against it; CI runs it on every pull request.
