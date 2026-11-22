# Application releases

## Approved deployment inputs

On a production host, the agent reads `CADENWAY_PRODUCTION_BRANCH` (default `production`)
for production and the shared edge. It verifies the selected commit with the SSH public
allowed-signers file at `CADENWAY_PRODUCTION_SIGNERS` (default
`/etc/cadenway/production-signers`), before checking it out. Keep that branch separate from
`CADENWAY_BRANCH` and restrict both applied refs to Ops-controlled updates. The application
release identities may propose changes. The host accepts production only after a separate
Ops authorization, so approval includes the exact Git tree. Bootstrap the production branch
from the last applied production and edge history. Roll back with a new approved commit
that restores the earlier versions and definitions.

Each released production app uses `tag@sha256:<digest>` in
`environments/prod/versions.env`. Ops verifies and records the digest of the approved artifact
before signing the production commit. The agent refuses an unpinned tag and writes the
approved image reference into the canonical service definition before Compose loads
environment variables. Bootstrap the signed branch with pins for all deployed apps. Tracking
new digests and signing the commit happen outside the host.

A non-production environment sharing the daemon with production needs a distinct signature
from `CADENWAY_RELEASE_SIGNERS` (default `/etc/cadenway/release-signers`). Its Compose
infrastructure, encrypted secrets and process settings must match the production-approved
tree. The non-production authorization can update its own service definitions and image tags.

The agent validates service manifests using its installed `compose-policy.py` before
decrypting the environment. The policy grants each service explicit interpolation variables
and permits only declared app resources, inline configs, and assigned network and ingress
settings. It stages canonical copies in `/run` for Compose. A new service environment
variable, Redis network or ingress setting requires the corresponding Ops policy update.
The [deployment guide](../docs/deployment.md) describes the repository protections and
promotion procedure.

## Readiness and batch recovery

The agent creates candidates with the normal Compose configuration and withholds
their internal service DNS aliases until readiness. They can still reach their
internal dependencies. Public candidates keep their edge endpoint throughout
startup. Traefik can publish each public candidate once it reports healthy while
the previous containers are still available for batch rollback. A public candidate
requires an explicit healthcheck and its environment's edge network configured
as the Traefik network.

Application candidates use dynamic bridge endpoints and consume inline configs.
Definitions with published ports, special endpoint settings, post-start hooks
or host-backed files fail before they can replace a running release.

An environment releases application services as a batch. The agent keeps the last
containers until the replacements have passed readiness, then promotes the candidates,
stops the obsolete containers and records the applied commit. The journal under the
agent state directory contains only the commit, fingerprints, container IDs and
network names and aliases. Before the applied marker is replaced, the next run
removes uncommitted candidates and restarts suspended containers. After that point,
the next run finishes retiring obsolete containers.

Database migrations and infrastructure changes apply separately from the application
batch. Keep migrations compatible with the previously running binaries. Network
promotion can refresh application connections while the previous containers are available.

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

Install this version of the agent on the staging host before enabling companions. Ansible copies
the executable to the host. Updating the GitOps repository alone updates the desired state.

An enabled companion is reconciled after its owner is ready. Replica changes keep
healthy matching containers. For an image or configuration change, the agent waits for healthy
replacement candidates before removing previous replicas. Account for up to two additional
containers during a replacement. A missing definition or zero replicas drains the companion before
starting an inline owner. When turning on dedicated processing, an old inline owner stops after its
replacement is ready and before the new companion starts. These stopped containers are retained
until the batch completes. Companion containers get up to 60 seconds to stop after `SIGTERM`.

Use separate staging changes for cutover and rollback. Deploy the extended Task schema and stop
the inline relay before enabling the companion. For a Task rollback, first set the companion to
zero, wait for any remaining reservations to expire, recover them and verify that no rows remain
leased. Then re-enable the inline relay. For Notification, disable the inline job execution before
enabling the worker. On rollback, stop the dedicated worker before re-enabling inline execution.
Keep the extended schema during both rollbacks.
