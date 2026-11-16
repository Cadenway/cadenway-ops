# Companion processes

The GitOps agent recognizes `task-service-relay` for `task-service` and
`notification-service-worker` for `notification-service`. A service's release carries its own
companion definition in the same Compose file. The companion uses the owner's image, release and
application `DATABASE_URL`. Its only network is `internal`. It needs an explicit healthcheck and
`deploy.replicas` of `0`, `1` or `2`. Only the owner receives the migrator URL in the one-off
migration command. Process selection belongs to the application image.

Set the desired capacity and the owner modes in the optional
`environments/<env>/processes.env` file. The agent accepts only these literal values and
rejects unknown or repeated keys.

| Setting                                | Values                |
| -------------------------------------- | --------------------- |
| `TASK_SERVICE_OUTBOX_MODE`             | `legacy`, `dedicated` |
| `TASK_SERVICE_RELAY_REPLICAS`          | `0`, `1`, `2`         |
| `NOTIFICATION_SERVICE_PROCESS_ROLE`    | `combined`, `api`     |
| `NOTIFICATION_SERVICE_WORKER_REPLICAS` | `0`, `1`, `2`         |

A positive replica count requires `dedicated` for Task or `api` for Notification in the
effective Compose configuration. Updating the file in Git triggers the agent without releasing
a new service image.

With Notification in `api` mode, the agent empties the owner-specific SMTP and email URL
overrides when it runs Compose. The worker still receives its mail configuration. Switching
the owner back to `combined` restores the shared mail configuration for inline delivery.

Install this version of the agent on the staging host before enabling companions. Ansible copies
the executable to the host. Updating the GitOps repository alone updates the desired state.

An enabled companion is reconciled after its owner applies successfully. Replica changes keep
healthy matching containers. For an image or configuration change, the agent waits for healthy
replacement candidates before removing previous replicas. Account for up to two additional
containers during a replacement. A missing definition or zero replicas drains the companion before
applying the owners. Companion containers get up to 60 seconds to stop after `SIGTERM`.

Use separate staging changes for cutover and rollback. Deploy the extended Task schema and stop
the inline relay before enabling the companion. For a Task rollback, first set the companion to
zero, wait for any remaining reservations to expire, recover them and verify that no rows remain
leased. Then re-enable the inline relay. For Notification, disable the inline job execution before
enabling the worker. On rollback, stop the dedicated worker before re-enabling inline execution.
Keep the extended schema during both rollbacks.
