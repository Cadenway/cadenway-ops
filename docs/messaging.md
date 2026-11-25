# NATS: users, subjects and streams

[Documentation index](README.md) · [Environments](../environments/README.md) · [Deployment](deployment.md)

One NATS server with JetStream per environment (`compose/infra.yaml`). The services reach it
through `@cadenway/nest-messaging`; the conventions of the events themselves (names, consumers,
retries) belong to cadenway-service-kit. This page is what the broker enforces.

## Users

`compose/nats/nats-server.conf` declares one user per backend. A connection without a user is
refused.

| User               | Backend                   | Publishes                                                                                                                                                                | Consumes ([consumers](#consumers))             |
| ------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------- |
| `identity`         | identity-service          | `evt.user.>`, `evt.session.>`, `evt.api-token.>`, `restricted.>`                                                                                                         | three consumers on `EVENTS`                    |
| `organization`     | organization-service      | `evt.organization.>`, `evt.member.>`, `evt.invitation.>`, `evt.domain.>`                                                                                                 | seven on `EVENTS`                              |
| `billing`          | billing-service           | `evt.subscription.>`, `evt.quota.>`, `evt.invoice.>`                                                                                                                     | six on `EVENTS`                                |
| `task`             | task-service              | `evt.space.>`, `evt.list.>`, `evt.task.>`, `evt.comment.>`, `evt.approval.>`, `evt.milestone.>`, `evt.intake.attachment-claimed.v1`, `evt.intake.attachment-released.v1` | five on `EVENTS`                               |
| `document`         | document-service          | `evt.doc.>`                                                                                                                                                              | nothing yet                                    |
| `storage`          | storage-service           | `evt.file.>`, `evt.intake.attachment-verified.v1`                                                                                                                        | nine on `EVENTS`                               |
| `notification`     | notification-service      | `evt.notification.>`, `evt.reminder.>`, `dlq.>`                                                                                                                          | twenty on `EVENTS`, two on `EVENTS_RESTRICTED` |
| `automation`       | automation-service        | `evt.automation.>`                                                                                                                                                       | two on `EVENTS`                                |
| `integration`      | integration-service       | `evt.git.>`                                                                                                                                                              | one on `EVENTS`                                |
| `search`           | search-service            | nothing                                                                                                                                                                  | 29 on `EVENTS`                                 |
| `api-gateway`      | API gateway               | `evt.api-usage.>`                                                                                                                                                        | nothing                                        |
| `realtime-gateway` | realtime gateway          | nothing                                                                                                                                                                  | 26 consumers on `EVENTS`                       |
| `admin`            | `nats-streams`, operators | everything                                                                                                                                                               | everything                                     |

A subject is `evt.<event-name>`. The entity normally decides who may publish; the shared
`intake` prefix uses exact event subjects for its two owners. The lists above are the events each service declares in its `AGENTS.md`, plus the
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

| User               | Consumer                                                 | Stream              | Filter                                      | Published by | For                                                                             |
| ------------------ | -------------------------------------------------------- | ------------------- | ------------------------------------------- | ------------ | ------------------------------------------------------------------------------- |
| `identity`         | `identity-service__project-member-joined`                | `EVENTS`            | `evt.member.joined.v1`                      | organization | Its projection of the memberships, checked when a session switches organization |
| `identity`         | `identity-service__project-member-role-changed`          | `EVENTS`            | `evt.member.role-changed.v1`                | organization | The same projection                                                             |
| `identity`         | `identity-service__project-member-removed`               | `EVENTS`            | `evt.member.removed.v1`                     | organization | The same projection                                                             |
| `organization`     | `organization-service__project-user-signed-up`           | `EVENTS`            | `evt.user.signed-up.v1`                     | identity     | Its directory of the users: names and e-mails in the member list                |
| `organization`     | `organization-service__project-user-email-verified`      | `EVENTS`            | `evt.user.email-verified.v1`                | identity     | The same directory                                                              |
| `organization`     | `organization-service__project-user-profile-updated`     | `EVENTS`            | `evt.user.profile-updated.v1`               | identity     | The same directory                                                              |
| `organization`     | `organization-service__project-user-email-changed`       | `EVENTS`            | `evt.user.email-changed.v1`                 | identity     | The same directory                                                              |
| `organization`     | `organization-service__project-user-two-step`            | `EVENTS`            | `evt.user.two-step-verification-changed.v1` | identity     | The same directory: the two-step verification column of the member list         |
| `organization`     | `organization-service__remove-deleted-user`              | `EVENTS`            | `evt.user.deleted.v1`                       | identity     | Removing the memberships of a deleted account                                   |
| `task`             | `task-service__project-member-joined`                    | `EVENTS`            | `evt.member.joined.v1`                      | organization | Its projection of the memberships: the roles it checks and the valid assignees  |
| `task`             | `task-service__project-member-role-changed`              | `EVENTS`            | `evt.member.role-changed.v1`                | organization | The same projection                                                             |
| `task`             | `task-service__project-member-removed`                   | `EVENTS`            | `evt.member.removed.v1`                     | organization | The same projection, which also unassigns a removed member                      |
| `notification`     | `notification-service__request-invitation-email`         | `EVENTS`            | `evt.invitation.issued.v1`                  | organization | The invitation e-mail                                                           |
| `notification`     | `notification-service__request-password-changed-email`   | `EVENTS`            | `evt.user.password-changed.v1`              | identity     | The password-changed security e-mail                                            |
| `notification`     | `notification-service__request-email-changed-email`      | `EVENTS`            | `evt.user.email-changed.v1`                 | identity     | The address-changed security e-mail                                             |
| `notification`     | `notification-service__request-new-device-email`         | `EVENTS`            | `evt.session.opened-on-new-device.v1`       | identity     | The new-device sign-in security e-mail                                          |
| `notification`     | `notification-service__request-deletion-scheduled-email` | `EVENTS`            | `evt.user.deletion-scheduled.v1`            | identity     | The deletion-scheduled security e-mail                                          |
| `notification`     | `notification-service__request-deletion-cancelled-email` | `EVENTS`            | `evt.user.deletion-cancelled.v1`            | identity     | The deletion-cancelled security e-mail                                          |
| `notification`     | `notification-service__request-two-step-email`           | `EVENTS`            | `evt.user.two-step-verification-changed.v1` | identity     | The two-step verification security e-mail                                       |
| `notification`     | `notification-service__request-code-email`               | `EVENTS_RESTRICTED` | `restricted.one-time-code.issued.v1`        | identity     | The code e-mail (see [restricted events](#restricted-events))                   |
| `notification`     | `notification-service__request-password-reset-email`     | `EVENTS_RESTRICTED` | `restricted.password-reset-link.issued.v1`  | identity     | The password reset e-mail (see [restricted events](#restricted-events))         |
| `realtime-gateway` | `realtime-gateway__relay-session-revoked`                | `EVENTS`            | `evt.session.revoked.v1`                    | identity     | Closing the sockets of a revoked session (invalidation)                         |
| `realtime-gateway` | `realtime-gateway__relay-session-organization-changed`   | `EVENTS`            | `evt.session.organization-changed.v1`       | identity     | Closing the sockets of a session that switched organization (invalidation)      |
| `realtime-gateway` | `realtime-gateway__relay-member-removed`                 | `EVENTS`            | `evt.member.removed.v1`                     | organization | Closing the sockets of a removed member (invalidation)                          |
| `realtime-gateway` | `realtime-gateway__relay-member-role-changed`            | `EVENTS`            | `evt.member.role-changed.v1`                | organization | Re-checking the rooms of a member whose role changed (invalidation)             |
| `realtime-gateway` | `realtime-gateway__relay-space-updated`                  | `EVENTS`            | `evt.space.updated.v1`                      | task         | Re-checking space rooms when its visibility or owner changes (invalidation)     |
| `realtime-gateway` | `realtime-gateway__relay-space-access-changed`           | `EVENTS`            | `evt.space.access-changed.v1`               | task         | Re-checking space rooms (invalidation)                                          |
| `realtime-gateway` | `realtime-gateway__relay-space-access-republished`       | `EVENTS`            | `evt.space.access-republished.v1`           | task         | Re-checking space rooms (invalidation)                                          |
| `realtime-gateway` | `realtime-gateway__relay-space-deleted`                  | `EVENTS`            | `evt.space.deleted.v1`                      | task         | Re-checking space rooms (invalidation)                                          |
| `realtime-gateway` | `realtime-gateway__relay-list-access-changed`            | `EVENTS`            | `evt.list.access-changed.v1`                | task         | Re-checking list rooms (invalidation)                                           |
| `realtime-gateway` | `realtime-gateway__relay-list-deleted`                   | `EVENTS`            | `evt.list.deleted.v1`                       | task         | Re-checking list rooms (invalidation)                                           |
| `realtime-gateway` | `realtime-gateway__relay-task-created`                   | `EVENTS`            | `evt.task.created.v1`                       | task         | Relaying the task created fact to list rooms                                    |
| `realtime-gateway` | `realtime-gateway__relay-task-archived`                  | `EVENTS`            | `evt.task.archived.v1`                      | task         | Relaying the task archived fact to list rooms                                   |
| `realtime-gateway` | `realtime-gateway__relay-task-unarchived`                | `EVENTS`            | `evt.task.unarchived.v1`                    | task         | Relaying the task unarchived fact to list rooms                                 |
| `realtime-gateway` | `realtime-gateway__relay-task-restored`                  | `EVENTS`            | `evt.task.restored.v1`                      | task         | Relaying the task restored fact to list rooms                                   |
| `realtime-gateway` | `realtime-gateway__relay-task-trashed`                   | `EVENTS`            | `evt.task.trashed.v1`                       | task         | Closing the rooms of a trashed task, then telling its list rooms (invalidation) |
| `realtime-gateway` | `realtime-gateway__relay-task-purged`                    | `EVENTS`            | `evt.task.purged.v1`                        | task         | Reconciling the rooms of a purged task (invalidation)                           |
| `realtime-gateway` | `realtime-gateway__relay-task-updated`                   | `EVENTS`            | `evt.task.updated.v1`                       | task         | The task change notice; a move re-checks its rooms (invalidation)               |
| `realtime-gateway` | `realtime-gateway__relay-task-status-changed`            | `EVENTS`            | `evt.task.status-changed.v1`                | task         | The task change notice                                                          |
| `realtime-gateway` | `realtime-gateway__relay-comment-created`                | `EVENTS`            | `evt.comment.created.v1`                    | task         | The comment notice                                                              |
| `realtime-gateway` | `realtime-gateway__relay-git-branch-created`             | `EVENTS`            | `evt.git.branch-created.v1`                 | integration  | The Git link notice, with `REALTIME_GIT_RELAYS_ENABLED`                         |
| `realtime-gateway` | `realtime-gateway__relay-git-pr-opened`                  | `EVENTS`            | `evt.git.pr-opened.v1`                      | integration  | The Git link notice, with `REALTIME_GIT_RELAYS_ENABLED`                         |
| `realtime-gateway` | `realtime-gateway__relay-git-pr-merged`                  | `EVENTS`            | `evt.git.pr-merged.v1`                      | integration  | The Git link notice, with `REALTIME_GIT_RELAYS_ENABLED`                         |
| `realtime-gateway` | `realtime-gateway__relay-git-pr-closed`                  | `EVENTS`            | `evt.git.pr-closed.v1`                      | integration  | The Git link notice, with `REALTIME_GIT_RELAYS_ENABLED`                         |
| `realtime-gateway` | `realtime-gateway__relay-git-checks-completed`           | `EVENTS`            | `evt.git.checks-completed.v1`               | integration  | The Git link notice, with `REALTIME_GIT_RELAYS_ENABLED`                         |
| `realtime-gateway` | `realtime-gateway__relay-notification-created`           | `EVENTS`            | `evt.notification.created.v1`               | notification | The inbox notice, with `REALTIME_PERSONAL_NOTICES_ENABLED`                      |
| `realtime-gateway` | `realtime-gateway__relay-reminder-due`                   | `EVENTS`            | `evt.reminder.due.v1`                       | notification | The reminder notice, with `REALTIME_PERSONAL_NOTICES_ENABLED`                   |

The following consumers are also declared by the current service sources. Some start only when
their feature switch or source connections are configured; the grants are present ahead of time.

| Backend                | Durable                                                    | Filter                                                 | Publisher      |
| ---------------------- | ---------------------------------------------------------- | ------------------------------------------------------ | -------------- |
| `organization-service` | `organization-service__project-seat-entitlement`           | `evt.subscription.changed.v1`                          | `billing`      |
| `billing-service`      | `billing-service__register-organization`                   | `evt.organization.created.v1`                          | `organization` |
| `billing-service`      | `billing-service__record-member-joined`                    | `evt.member.joined.v1`                                 | `organization` |
| `billing-service`      | `billing-service__record-member-role-changed`              | `evt.member.role-changed.v1`                           | `organization` |
| `billing-service`      | `billing-service__record-member-removed`                   | `evt.member.removed.v1`                                | `organization` |
| `billing-service`      | `billing-service__record-file-uploaded`                    | `evt.file.uploaded.v1`                                 | `storage`      |
| `billing-service`      | `billing-service__record-file-deleted`                     | `evt.file.deleted.v1`                                  | `storage`      |
| `task-service`         | `task-service__verify-intake-attachment`                   | `evt.intake.attachment-verified.v1`                    | `storage`      |
| `task-service`         | `task-service__decide-notification-delivery-authorization` | `evt.notification.delivery-authorization-requested.v1` | `notification` |
| `storage-service`      | `storage-service__record-task-purge`                       | `evt.task.purged.v1`                                   | `task`         |
| `storage-service`      | `storage-service__apply-storage-byte-entitlement`          | `evt.subscription.changed.v1`                          | `billing`      |
| `storage-service`      | `storage-service__claim-intake-attachment`                 | `evt.intake.attachment-claimed.v1`                     | `task`         |
| `storage-service`      | `storage-service__release-intake-attachment`               | `evt.intake.attachment-released.v1`                    | `task`         |
| `storage-service`      | `storage-service__apply-avatar-change`                     | `evt.user.avatar-changed.v1`                           | `identity`     |
| `storage-service`      | `storage-service__abandon-avatar-upload`                   | `evt.user.avatar-upload-abandoned.v1`                  | `identity`     |
| `storage-service`      | `storage-service__delete-avatar-owner`                     | `evt.user.deleted.v1`                                  | `identity`     |
| `storage-service`      | `storage-service__apply-organization-logo-change`          | `evt.organization.logo-changed.v1`                     | `organization` |
| `storage-service`      | `storage-service__abandon-organization-logo-upload`        | `evt.organization.logo-upload-abandoned.v1`            | `organization` |
| `notification-service` | `notification-service__activity-task-delivery-authorized`  | `evt.task.notification-delivery-authorized.v1`         | `task`         |
| `notification-service` | `notification-service__inbox-task-delivery-authorized`     | `evt.task.notification-delivery-authorized.v1`         | `task`         |
| `notification-service` | `notification-service__inbox-task-assigned`                | `evt.task.assigned.v1`                                 | `task`         |
| `notification-service` | `notification-service__inbox-task-status-changed`          | `evt.task.status-changed.v1`                           | `task`         |
| `notification-service` | `notification-service__inbox-comment-created`              | `evt.comment.created.v1`                               | `task`         |
| `notification-service` | `notification-service__inbox-comment-updated`              | `evt.comment.updated.v1`                               | `task`         |
| `notification-service` | `notification-service__inbox-description-mentions-changed` | `evt.task.description-mentions-changed.v1`             | `task`         |
| `notification-service` | `notification-service__inbox-approval-requested`           | `evt.approval.requested.v1`                            | `task`         |
| `notification-service` | `notification-service__inbox-approval-decided`             | `evt.approval.decided.v1`                              | `task`         |
| `notification-service` | `notification-service__inbox-task-access-requested`        | `evt.task.access-requested.v1`                         | `task`         |
| `notification-service` | `notification-service__inbox-task-access-approved`         | `evt.task.access-request-decided.v1`                   | `task`         |
| `notification-service` | `notification-service__notify-quota-threshold`             | `evt.quota.threshold-reached.v1`                       | `billing`      |
| `notification-service` | `notification-service__reminder-task-delivery-authorized`  | `evt.task.notification-delivery-authorized.v1`         | `task`         |
| `automation-service`   | `automation-service__run-task-created-rules`               | `evt.task.created.v1`                                  | `task`         |
| `automation-service`   | `automation-service__run-task-status-changed-rules`        | `evt.task.status-changed.v1`                           | `task`         |
| `integration-service`  | `integration-service__purge-task-git-links`                | `evt.task.purged.v1`                                   | `task`         |
| `search-service`       | `search-service__index-task-created-v1`                    | `evt.task.created.v1`                                  | `task`         |
| `search-service`       | `search-service__index-task-updated-v1`                    | `evt.task.updated.v1`                                  | `task`         |
| `search-service`       | `search-service__index-task-archived-v1`                   | `evt.task.archived.v1`                                 | `task`         |
| `search-service`       | `search-service__index-task-unarchived-v1`                 | `evt.task.unarchived.v1`                               | `task`         |
| `search-service`       | `search-service__index-task-trashed-v1`                    | `evt.task.trashed.v1`                                  | `task`         |
| `search-service`       | `search-service__index-task-restored-v1`                   | `evt.task.restored.v1`                                 | `task`         |
| `search-service`       | `search-service__index-task-purged-v1`                     | `evt.task.purged.v1`                                   | `task`         |
| `search-service`       | `search-service__index-task-watcher-changed-v1`            | `evt.task.watcher-changed.v1`                          | `task`         |
| `search-service`       | `search-service__index-comment-created-v1`                 | `evt.comment.created.v1`                               | `task`         |
| `search-service`       | `search-service__index-comment-updated-v1`                 | `evt.comment.updated.v1`                               | `task`         |
| `search-service`       | `search-service__index-comment-deleted-v1`                 | `evt.comment.deleted.v1`                               | `task`         |
| `search-service`       | `search-service__index-list-created-v1`                    | `evt.list.created.v1`                                  | `task`         |
| `search-service`       | `search-service__index-list-updated-v1`                    | `evt.list.updated.v1`                                  | `task`         |
| `search-service`       | `search-service__index-list-archived-v1`                   | `evt.list.archived.v1`                                 | `task`         |
| `search-service`       | `search-service__index-list-unarchived-v1`                 | `evt.list.unarchived.v1`                               | `task`         |
| `search-service`       | `search-service__index-list-deleted-v1`                    | `evt.list.deleted.v1`                                  | `task`         |
| `search-service`       | `search-service__index-list-restored-v1`                   | `evt.list.restored.v1`                                 | `task`         |
| `search-service`       | `search-service__index-list-access-changed-v1`             | `evt.list.access-changed.v1`                           | `task`         |
| `search-service`       | `search-service__index-space-created-v1`                   | `evt.space.created.v1`                                 | `task`         |
| `search-service`       | `search-service__index-space-updated-v1`                   | `evt.space.updated.v1`                                 | `task`         |
| `search-service`       | `search-service__index-space-deleted-v1`                   | `evt.space.deleted.v1`                                 | `task`         |
| `search-service`       | `search-service__index-space-restored-v1`                  | `evt.space.restored.v1`                                | `task`         |
| `search-service`       | `search-service__index-space-access-changed-v1`            | `evt.space.access-changed.v1`                          | `task`         |
| `search-service`       | `search-service__index-space-access-republished-v1`        | `evt.space.access-republished.v1`                      | `task`         |
| `search-service`       | `search-service__index-doc-created-v1`                     | `evt.doc.created.v1`                                   | `document`     |
| `search-service`       | `search-service__index-doc-updated-v1`                     | `evt.doc.updated.v1`                                   | `document`     |
| `search-service`       | `search-service__index-doc-deleted-v1`                     | `evt.doc.deleted.v1`                                   | `document`     |
| `search-service`       | `search-service__index-file-uploaded-v1`                   | `evt.file.uploaded.v1`                                 | `storage`      |
| `search-service`       | `search-service__index-file-deleted-v1`                    | `evt.file.deleted.v1`                                  | `storage`      |

Document and the API gateway declare no JetStream consumers. PostgreSQL-backed `nest-jobs`
queues do not require JetStream consumer grants. Task publishes `evt.intake.attachment-claimed.v1`
and `evt.intake.attachment-released.v1`; Storage publishes `evt.intake.attachment-verified.v1`.
These exact subjects keep the shared `intake` prefix from granting either service the other's events.

### Rebuild advisories

`SEARCH_REBUILD_ADVISORIES` captures the terminal advisories of the 29 Search source consumers, and
`BILLING_REBUILD_ADVISORIES` those of the six Billing usage observation consumers. Each service
reads the stream information of its own latch only. Each latch keeps only the last advisory.

From search-service 0.4.0 and billing-service 0.4.0, both services read their latch with
`consumerAdvisoryStreamState` of `@cadenway/nest-messaging` (0.9 or later), which reports the latch's creation time and last sequence with its state. The last
sequence survives a purge and grows with each advisory, and the creation time changes when the
latch is recreated. Each rebuild is fenced by two clear and identical observations, one when it
starts and one when it is promoted, and the promoted generation keeps them. Whenever the latch
later differs from them, even after a purge, the service rebuilds on its own:

- **Billing** reads usage only while its latch is clear and matches the observation certified with
  the active usage generation. A held advisory, or a latch that changed since that certification,
  makes it invalidate the active usage of each organization it advances (`AdvanceUsageRebuild`) and
  rebuild it from the organization and storage pages; measured usage is unavailable until the new
  generation is promoted, which needs a clear latch.
- **Search** promotes a new index generation only on clear, identical observations; a held
  advisory blocks the promotion, while an active index keeps serving. An active index whose latch
  changed since its certification, an advisory recorded meanwhile even if purged since, or a
  recreated latch, is rebuilt from its owners.

An `unknown` observation (stream unreadable, configuration not matching) neither certifies nor
discards a generation. Matching observations prove that no advisory was recorded only while the
latch kept capturing every monitored subject: provisioning adds subjects and never removes one from
a live latch, and stops monitoring a subject only by recreating the latch, which changes its
creation time.

The dead letters are not a complete history of what was given up: the dead-letter worker copies
only the advisories it received while it ran, and `EVENTS_DLQ` keeps 30 days and 256 MiB. Use them
to find the affected resources, never to prove that nothing else was lost. A latch created closed
(first provisioning while the service already consumes, or a lost latch) has no history at all.
To clear `SEARCH_REBUILD_ADVISORIES` or `BILLING_REBUILD_ADVISORIES` (`<latch>` below), run the
commands in the `nats-streams` container, as the `admin` user:

1. Note the last sequence and the creation time of the latch, `nats stream info <latch>`
   (`Last Sequence`, `Created`), and read its advisory with `nats stream view <latch>`.
2. List the dead letters of its service to find the affected resources, for each watched handler:
   `nats stream view EVENTS_DLQ --subject 'dlq.search-service__<handler>.>'` (Search) or
   `nats stream view EVENTS_DLQ --subject 'dlq.billing-service__<handler>.>'` (Billing).
3. Check the releases that actually run, not only the desired ones of `environments/<env>/versions.env`
   (a failed rollout keeps the previous container serving): the image tag of every running
   search-service and billing-service container on the host, `docker ps --format '{{.Image}}'`,
   and the last deployment outcome. When a tag is older than 0.4.0 or uncertain, follow the second
   case below.
   - From search-service 0.4.0 and billing-service 0.4.0 on, clear once the affected resources
     are noted. Purging hides nothing from them: the advisory raised the latch's last sequence,
     so each projection certified before it is rebuilt once the latch is clear again, whether or
     not they read it while it was held.
   - With an older release of either, make its projection whole before clearing. Billing: leave
     the latch held until the usage scheduler, which advances the enrolled organizations page by
     page every two seconds, has invalidated the usage of each of them. Search: clear only when no
     index has ever been promoted (a first provisioning), or when the active index and any build
     in progress are known to be complete; otherwise leave the latch held, since a purge would let
     a build begun before the advisory be promoted.
4. Read `nats stream info <latch>` again: if its creation time changed, the latch was created
   again meanwhile (a start of `nats-streams` after a durable was removed, or a lost latch) and
   its sequences start over, so go back to step 1. Otherwise purge up to that sequence only, so
   that an advisory recorded meanwhile stays latched, right after that read and outside a rollout
   of `nats-streams`: `nats stream purge <latch> --seq <last sequence + 1> --force`.

These steps never touch `REALTIME_AUTHORIZATION_ADVISORIES`, which has its own
[procedure](#realtime-authorization-advisories) and reconciliation.

A latch starts empty only while `EVENTS` has no consumer of its service: a new environment, or a
broker that lost `EVENTS` or those consumers too. Then the empty latch guards a rebuild, not an
old projection: Search (`brokerIdentityChanged`) and Billing (`BillingUsageBrokerProof`) record
the creation time of `EVENTS` and of each of their consumers with their active state, and a
recreated stream or consumer makes Search rebuild its index and Billing invalidate its usage.

A latch is added allowing two messages, a configuration no service trusts, and takes its
single-message configuration only once the marker it needs is stored, so a pass interrupted in
between never leaves an empty latch the services would trust; the next pass finishes it. As for
the realtime latch, the dead-letter worker of notification-service logs a marker as an unreadable
advisory. Changes to either durable list require the same
[coordinated cutover](#changing-the-invalidation-consumers) as the realtime list.

The realtime gateway starts its five Git consumers and its two personal notice consumers only when
its [relay switches](service-environment.md#realtime-relays) are on; the grant is there in every
environment either way, and a consumer it does not start uses none of it. Its thirteen
invalidation consumers also feed the [realtime latch](#realtime-authorization-advisories).

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
`NATS_SERVER_CONF_SHA256`. The test fails when the configuration and its list differ. Run its static portion without Docker
using `bash compose/tests/nats-permissions.sh --inventory-only`. The list is a reviewed snapshot;
checking for newly declared service consumers also requires comparing it with the service sources.

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

| Stream                              | Subjects             | Kept         | Size cap  | Holds                                                                                                             |
| ----------------------------------- | -------------------- | ------------ | --------- | ----------------------------------------------------------------------------------------------------------------- |
| `EVENTS`                            | `evt.>`              | 7 days       | 1 GiB     | Every event                                                                                                       |
| `EVENTS_RESTRICTED`                 | `restricted.>`       | 1 hour       | 64 MiB    | The restricted events                                                                                             |
| `EVENTS_DLQ`                        | `dlq.>`              | 30 days      | 256 MiB   | Messages a consumer gave up on (dead letters)                                                                     |
| `REALTIME_AUTHORIZATION_ADVISORIES` | 26 advisory subjects | until purged | 1 message | The last authorization invalidation the realtime gateway gave up on ([latch](#realtime-authorization-advisories)) |
| `SEARCH_REBUILD_ADVISORIES`         | 58 advisory subjects | until purged | 1 message | Last Search source consumer advisory ([latch](#rebuild-advisories))                                               |
| `BILLING_REBUILD_ADVISORIES`        | 12 advisory subjects | until purged | 1 message | Last Billing usage consumer advisory ([latch](#rebuild-advisories))                                               |

File storage, oldest messages dropped first, duplicates of a `Nats-Msg-Id` refused for two minutes.
The sizes are starting values.

A restricted event carries a single-use code valid ten minutes, or a link that expires as soon. One
hour delivers it through a short outage of notification-service, and none stays readable in the
stream past its use.

No backend can create, change, purge or delete a stream. The `nats-streams` container of
`compose/infra.yaml` owns them: it runs `compose/nats/ensure-streams.sh` with the `admin` user,
creates or updates the six streams at start, then checks every minute that they exist and
creates again one the broker lost. It is healthy while all six exist. A changed limit reaches a
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

## Realtime authorization advisories

The realtime gateway closes or re-checks a socket whose session, membership or room visibility an
event invalidates. When one of its thirteen invalidation consumers gives a message up, after its
last delivery or on a terminate, a socket could keep a right it lost. The server then publishes an
advisory, `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS.<consumer>` or `MSG_TERMINATED`, and
the stream `REALTIME_AUTHORIZATION_ADVISORIES` captures those 26 subjects: it keeps one message,
the last, with no age or size limit.

Each replica of the gateway reads the stream information, its user's only right on the stream,
about every second. It admits a socket, and answers ready, only while the stream exists with exactly
that configuration and holds no message (`isEmptyConsumerAdvisoryStream` of
`@cadenway/nest-messaging` checks every field). An advisory therefore takes every replica out of
service until an operator clears the latch. The GitOps agent fails a gateway rollout meanwhile,
since the new container never turns healthy: after clearing, apply any gateway change merged in
the meantime with a new commit.

The latch is a flag, not a record: it keeps only the last advisory. The given-up messages
themselves are the dead letters the [dead-letter worker](#dead-letters) copied from `EVENTS`, kept
30 days. To clear it:

1. Note the last sequence of the latch: `nats stream info REALTIME_AUTHORIZATION_ADVISORIES`
   (`Last Sequence`), and read its advisory with `nats stream view`.
2. List every dead letter of the invalidation consumers, not only the latched one, with
   `nats stream view EVENTS_DLQ --subject 'dlq.realtime-gateway__<handler>.>'` for each of them
   (a wildcard covers whole tokens only), and reconcile what each changed: the sessions,
   memberships or visibility it concerned, closing the affected sockets by restarting the gateway
   if needed. The dead letters are not a complete history (see
   [rebuild advisories](#rebuild-advisories)): when the latch holds a marker, or the worker may
   have missed advisories, restart the gateway so that every socket is authorized again.
3. Purge up to that sequence only, so that an advisory recorded during the reconciliation stays
   latched: `nats stream purge REALTIME_AUTHORIZATION_ADVISORIES --seq <last sequence + 1> --force`.

Run the commands in the `nats-streams` container (`docker compose exec nats-streams nats ...`),
as the `admin` user. No backend may purge or delete the stream.

`compose/nats/ensure-streams.sh` creates the stream empty while `EVENTS` has no consumer of the
gateway, its first provisioning. A latch lost afterwards (removed by hand, or not recovered by the
broker) may have held an advisory, and those published while it was missing are lost: the script
creates it again closed, holding a marker (`io.cadenway.realtime.latch-recreated`), which an
operator clears in the same way. It adds a latch allowing two messages, a configuration the gateway
does not trust, lists the consumers only then, stores the marker if one is needed, and sets the
single-message configuration last: a pass stopped in between leaves a latch the next pass finishes,
never an empty one the gateway would trust. The dead-letter worker of notification-service sees that
marker on the advisory subject and logs it as an unreadable advisory. A broker that lost `EVENTS`
and its consumers too starts the latch empty, like a new environment.

### Changing the invalidation consumers

The script lists the thirteen invalidation consumers, the `relayInvalidationHandlers` of the
gateway, and the check of the kit requires the latch subjects to be exactly theirs: a running
release whose list differs refuses every socket. A change to that list is therefore a cutover, not
an addition. Grant any new consumer first, keeping the old list. The latch list is one declaration
for every environment, while the gateway release reaches staging and then production separately:
whenever the new list is merged, the environments whose gateway runs the other list refuse
sockets until the release reaches them. Merge it when the release is about to be deployed and
promote it promptly. Accepting a superset of subjects in `@cadenway/nest-messaging` would remove
that window. A removed handler keeps its grant until no running release uses it. The same
cutover applies to the Search and Billing rebuild advisory durable lists: a mismatched list blocks
the corresponding proof until the service release and latch declaration agree.

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
a filter nobody was given is refused to the backend it would belong to. For the realtime latch, it
checks every setting the kit requires, at creation and after each restart, its subjects against
granted consumers, that only the gateway reads it and no backend clears it, that a terminated
invalidation is latched and cleared by an operator, and that a lost latch comes back closed.
