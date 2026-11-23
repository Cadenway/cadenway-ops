# Deployment and operations

[Documentation index](README.md) · [Architecture](architecture.md) · [Environments](../environments/README.md)

## How a release reaches a server

1. A pull request merged on a service's `main` updates its release pull request (release-please).
2. Merging the release pull request tags `vX.Y.Z`; the service's `release.yml` builds the image
   `ghcr.io/<org>/cadenway-<service>:X.Y.Z` (linux/amd64) and calls its `deploy.yml`.
3. Ops reviews the service definition and version for the target environment. Production uses a
   distinct protected ref and the image tag and digest approved by Ops. See
   [GitOps approval and service definitions](#gitops-approval-and-service-definitions).
4. On each host, the GitOps agent (`agent/cadenway-agent.sh`, a systemd timer every minute) fetches
   the configured refs. For each approved environment it decrypts the secrets into `/run`,
   refuses a commit that
   leaves a variable unset, brings the infrastructure up, then for each deployable whose fingerprint
   changed (image, environment, definition, mounted config contents) or whose container is not
   healthy, runs its migrations in a one-off container (`node dist/migrate.js` when the image has
   it), to which it gives the migrator URL of its database ([database](database.md#variables)),
   prepares new containers beside the previous ones and waits for readiness. Candidates receive their
   internal service DNS aliases at promotion. The agent suspends obsolete containers and records the
   applied commit before retiring them. Until then, the journal lets the agent remove candidates and
   restore suspended containers, whose readiness it checks before clearing the journal. Database
   migrations and infrastructure changes remain in place during application rollback. See
   [Application releases](../agent/README.md#application-releases).
5. The outcome of a commit, posted to `ALERT_WEBHOOK_URL`:
   - **applied**: with the duration;
   - **failed** when the desired state itself is wrong (unhealthy container, failed migration,
     missing variable, secrets this host cannot decrypt): recovery restores the previous application
     release, and a new commit is required for another attempt;
   - **retrying** when the cause is transient (image not pullable yet, registry login, infrastructure
     slow to start, edge network missing): reported once. The agent recovers the application batch
     and retries on the next tick.

Nothing connects to a host to deploy: the host pulls with a read-only deploy key.

To roll back an applied release, create a new approved commit with the previous definition and
image. Use the original approved digest for production. The new commit must descend from the
applied commit so the agent can distinguish an authorized rollback from a ref rewind.

## Host topology

Use a dedicated VPS for each hosted environment. Set `cadenway_environments: [staging]` on the
staging host and `cadenway_environments: [prod]` on the production host. Allocate independent
storage for the operating systems, Docker images and writable layers, and service data. A
container CPU or memory limit cannot protect another environment's disk allocation.

Traefik owns ports 80 and 443 on each VPS. Public application services join their assigned named
edge network. Their routes and networks use the environment recorded by the host, and their
hostnames use its configured domain.

Before switching an old shared VPS to this policy, move staging to its independent host, retire
its containers from the original Docker daemon, and confirm any pending restore or rollout is
reconciled. Keep storage volumes and backups until the move is verified. The agent leaves existing
containers alone when it refuses an invalid host assignment.

## Setting up a host

Prerequisites, once: the GitHub organization, a GitHub App (the deploy app) installed on every
service repository and on `cadenway-ops`, with contents and pull requests write; DNS records
pointing at its host for each environment's domain itself and its `www.`, `app.`, `api.` and
`realtime.` (production: `cadenway.com`, `www.cadenway.com`, `app.cadenway.com`, `api.cadenway.com`,
`realtime.cadenway.com`; staging: the same under `staging.cadenway.com`). The images are amd64:
the host must be too.

1. Fill `ansible/inventory/hosts.yml` from `hosts.example.yml`, and
   `ansible/inventory/group_vars/cadenway.yml` (admin keys, repository URL, image owner, domains,
   backup recipient).
2. From the repository root, preview then apply (an operator, never an agent):

   ```bash
   ansible-galaxy collection install -r ansible/requirements.yml
   ansible-playbook ansible/playbooks/setup.yml --check --diff -e ansible_user=ubuntu
   ansible-playbook ansible/playbooks/setup.yml -e ansible_user=ubuntu
   ```

   Before it restricts SSH to the admin user, the play logs in as that user from the controller with
   its key, and stops if it cannot. Later runs connect as the admin user and need no `-e` (add
   `-e ansible_port=22` on the first run when `cadenway_ssh_port` is another port). The preview of a
   fresh host skips the steps that need an earlier one to have run, such as the firewall before ufw
   is installed.

3. The play prints the host's **age recipient** and **deploy key**:
   - add the deploy key to `cadenway-ops` as a read-only deploy key;
   - add the recipient to `.sops.yaml` and re-encrypt (see [environments](../environments/README.md)).
4. Create or update `environments/<env>/secrets.sops.env` with `sops`, then merge. The agent applies
   it within a minute: `journalctl -u cadenway-agent -f` on the host.

A later change of a host's settings (domain, image owner, environments) through `setup.yml` makes the
agent apply the current commit again at once.

`ansible/tests/run.sh` runs these four steps (fresh preview, apply, idempotent apply, preview) against
a throwaway Ubuntu 24.04 container in CI.

## GitOps approval and service definitions

| Where                                 | Setting                                                                                                   |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Organization variables                | `CADENWAY_DEPLOY_APP_CLIENT_ID`                                                                           |
| Each service repository, environments | `release`, `staging`, `production`, each limited to the `main` branch; required reviewers on `production` |
| The same three environments           | the environment secret `CADENWAY_DEPLOY_APP_PRIVATE_KEY`; never an organization or repository secret      |
| `cadenway-ops` release refs           | protect the staging and production refs independently and remove the deploy App from their bypass lists   |
| GHCR packages                         | public, or `GHCR_PULL_USER` and `GHCR_PULL_TOKEN` in the environment's secrets                            |

Service release workflows publish images and submit their proposed Compose definition and version
to Ops for review. The legacy workflow copies that push directly to the Ops default branch must
use a proposal branch or have their changes applied by an Ops maintainer before enabling this setup.
The service App's installation must not hold either approval signing key.

On a production host the agent fetches a separate protected ref, configured by
`cadenway_production_branch` (default `production`). Ops promotion signs the final commit with
the independent SSH signing key whose public allowed-signers line is provisioned through
`cadenway_production_signers`. That commit must descend from the previously applied production
and edge heads. Apply a rollback through a newly approved commit containing the intended older
definitions. Bootstrap the production ref ahead of enabling this agent on an existing host.

Ansible installs the public approval keys and the Compose policy. Each environment's protected ref
must include the exact approved image pin for every released service in `versions.env`. The agent
requires `tag@sha256:<digest>` in staging and production, including the image used for companions
and migrations. Bootstrap both release refs with verified registry digests before enabling this
policy. A legacy ref containing only tags is refused.

The agent resolves interrupted restores and releases under its host lock before contacting the Git
remote. Each reconciliation requires a successful fetch of its own approval ref.

The installed policy sets the following per-container ceilings on hosted application services,
including one-off migrations. The memory ceiling includes the container's swap allowance.

| Process              | vCPU |  Memory | PIDs |
| -------------------- | ---: | ------: | ---: |
| Backend or companion | 0.50 | 256 MiB |  128 |
| Frontend             | 0.25 |  64 MiB |   64 |

The current allowlist and maximum companion replicas give one full application generation a
combined ceiling of 8.5 vCPU, 4,224 MiB and 2,176 PIDs. Size each host for the extra generation
during rollout. Budget additional capacity for PostgreSQL, Redis, NATS, Traefik, object
storage, the operating system and other host workloads. These limits are ceilings. Verify capacity
and Linux cgroup enforcement on the host.

For an existing daemon, activate an approved release that recreates historical application
containers with the new limits. Confirm the effective limits on the running containers and on
any retained rollback candidates before relying on the budget. Reconciliation of an already
applied release retains healthy containers whose configuration matches the approved release.
Local recovery can still restart historical containers with their original limits.

The agent compiles included service definitions against its installed per-service policy before
decryption. Only the public services can join the edge network. The policy expands the known route
names to static labels and checks the resolved model against the assigned network and hostname.
Update that policy through Ops review when a service needs a new variable, network, configuration
or routing label. Service publishing credentials are not approval credentials.

Keep all Traefik labels in the approved Compose files. The agent checks the pulled image before
either migration or creation of a replacement. Both steps use the checked local image without a
second pull. At bootstrap, replace or verify containers created before this check was active,
including the previous containers that might be used for local rollback.

When switching an existing stack to the separate Redis instances, verify both gateways are healthy
with their dedicated stores, then stop the old shared Redis container if it is still present.
Preserve its volume until the switch is confirmed. Counters and realtime markers in the old store
are ephemeral and activity must be re-established against the new stores.

## Backups

`cadenway-backup.timer` dumps every service database of every environment of the host each night.
It encrypts `pg_dump --format=custom` to `cadenway_backup_age_recipient` and stages only the ciphertext
in a private directory under `/var/lib`. Allocate enough local disk space for the largest encrypted
service archive. Each archive is stored under
`<bucket>/<env>/<timestamp>/<database>-<sha256>.dump.age`. Backup publishes
`<database>.manifest.json` last. It carries an Ed25519 signature over the format version,
environment, timestamp, database, bucket, archive key, byte count and SHA-256. The digest identifies
the exact encrypted generation independently of the Object Storage provider's version identifiers.

Provision the signing identity out of band on the backup host at
`/etc/cadenway/backup-signing.key`, readable only by root. Use a dedicated OpenSSH Ed25519 key
available to the non-interactive backup service. The signing identity is independent of any
Object Storage credential and of the age recipient. Configure `cadenway_backup_signing_public_keys`
in the host inventory with the matching OpenSSH public key lines without comments. Ansible pins
these keys for both backup publication and restore. For a rotation, pin the new key before switching
signers and keep the previous verification key until the last snapshot it signed expires.

Protect archive and manifest objects with a 30-day independent bucket retention policy. Grant
the host identity permission to publish and read backup objects. Keep permissions to delete
objects, shorten retention or bypass immutability with a separate administrative identity.
Use provider-enforced immutability where available and apply lifecycle expiry to both the manifest
and its archive. Failed publications may leave encrypted archives without manifests. They expire
under the same bucket lifecycle and are ineligible for restore. A backup failure posts to
`ALERT_WEBHOOK_URL`. Run a backup with
`ansible-playbook ansible/playbooks/backup.yml --limit <host>`.

A restore overwrites live data; the playbook asks for the environment twice and the backup private
key, which it removes from the host afterwards:

```bash
ansible-playbook ansible/playbooks/restore.yml --limit cadenway-prod \
  -e cadenway_restore_environment=prod -e cadenway_restore_confirm=prod \
  -e cadenway_restore_timestamp=20261112T030512Z \
  -e cadenway_restore_identity_file=~/.config/cadenway/backup.key
```

The restore holds the GitOps lock. It checks the manifest against the pinned public keys and the
requested snapshot, then verifies the downloaded ciphertext length and digest before any database
change. Produce and verify a signed snapshot before cutting over from a system that holds only
unsigned backups. Keep historical archives under their existing retention. They require separate
operator-led provenance verification.

The restore loads the archive into a temporary database and validates the contents under the
service's migrator role before stopping the running application and its workers. Separate
cluster administration connections handle creation and cutover. When the live database exists,
its Drizzle migration history must match the archive. Use a backup compatible with the running
application version. The restore then switches the database names in one transaction and verifies
that all previously running containers are healthy after the last companion has started.
Containers already stopped stay stopped.
When several databases are requested, each is restored and switched independently.

After a successful switch, the former database remains under the reported
`cw_restore_previous_…` name with connections disabled. It consumes disk space until an operator
removes it after verification. If startup fails, the command attempts to return the former
database to its original name and restart the previous set of containers. A candidate that
served under the live name is retained under `cw_restore_failed_…` with connections disabled.
Inspect it for any writes accepted before rollback. Investigate a reported rollback failure
before restarting services manually.

Before stopping application containers, the restore persists the old and candidate database
identities, running container IDs and its current phase on the host. After an abrupt interruption,
the agent resolves that journal under the same lock before the next reconciliation. To run recovery
directly, invoke `cadenway-restore --recover <environment>` on the assigned host. A pending switch
recovers the verified old database and workloads. A committed switch keeps the recovered database
after verifying its identity and workload health. Investigate any refused recovery before resuming
reconciliation.

An interruption while the archive loads, before cutover begins, leaves the active service in place.
Check for an abandoned candidate database and temporary encrypted archive after such an interruption.

Once Identity uses Organization's account-deletion reservations, suspend GitOps reconciliation
during this maintenance window so it cannot restart paused workers. Pause Identity's deletion
workers and drain in-flight attempts before restoring either database. Reconcile pending Identity
attempt IDs with the restored Organization reservations and current ownership before resuming
the workers and GitOps. Keep rollback images for both services that preserve this protocol.

To recover Task with a fresh membership projection, run a Task-only restore:

```sh
cadenway-restore --rebuild-task-memberships <environment> <timestamp> <identity-file> task
```

This mode requires one running Organization container with the membership export command, one
running Task container with the rebuild command, and their environment's PostgreSQL on the Compose
internal network. Keep the live Organization database authoritative at a point in time at least
as recent as the Task backup. A coupled rollback of Organization and Task requires separate
coordination. The flag is explicit so the general restore remains compatible with images without
these commands.

The restore stops Task and its relay before streaming the current Organization membership catalog
into a disposable process using the exact Task image. The catalog includes removed memberships
and their versions. The importer receives only the Task application connection and writes to the
candidate database. With Task stopped, concurrent changes after the Organization snapshot remain
for its durable membership consumers to apply after restart. Keep the membership stream and its
durable consumers available through the restore. The outage includes the catalog export and
import. Either command failing prevents the switch. Recovery removes an abandoned importer,
discards the unswitched candidate and resumes the prior Task workloads.

For a local test with the two real maintenance commands, build the backup runner below and supply
two locally built service images that include the commands. The runner applies both migrations to
disposable PostgreSQL databases and verifies that the restored Task uses the newer Organization
roles and tombstones. It runs the maintenance commands without starting either HTTP service.

```sh
task_image=$(docker image inspect --format '{{.Id}}' task-service:local)
organization_image=$(docker image inspect --format '{{.Id}}' organization-service:local)
docker run --rm --init --network none \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/ansible/roles/backup:/backup:ro" \
  -e CADENWAY_E2E_PREPARED=1 \
  -e "CADENWAY_E2E_TASK_IMAGE=$task_image" \
  -e "CADENWAY_E2E_ORGANIZATION_IMAGE=$organization_image" cadenway-backup-e2e:local
```

For the `storage` database, the restore inventories durable objects referenced by the candidate
before stopping Storage. That includes elected attachments of tasks that have not been purged,
verified Intake reservations and prepared or attached media of active profile owners. After
stopping Storage, the restore conditionally recreates
missing current objects from their exact historical versions before switching the PostgreSQL names.
Each recreation adds a version and preserves the earlier versions and delete markers. Existing
objects with matching history stay in place. Missing history, divergent versions or a conflicting
concurrent write prevent promotion. Objects successfully recreated before a failed cutover remain
available for a retry. Storage is offline while the restore checks the application bucket again
and transfers missing objects. The outage grows with the number of references and bytes to recover.

Keep S3 versioning enabled on the application bucket and retain noncurrent versions for the full
retention period of the PostgreSQL dumps. Use a backend that supports versioned reads and
`PutObject` with `If-None-Match: *` after a delete marker. The restore requires consistent
object sizes and ETags across retained payload versions and checks the ETag after recreation.
Storage recovery uses the application bucket and a [dedicated restore identity](service-environment.md#secrets).
The encrypted dump protects database metadata, and the application bucket retains the object
bytes separately.

In Compose, set `STORAGE_S3_ERASE_TRANSIENT_VERSIONS=true` for the versioned application bucket.
Storage's runtime identity needs `s3:ListBucketVersions` and `s3:DeleteObjectVersion` for transient
attachment and profile-media cleanup, plus `s3:GetObject` and `s3:PutObject` on
`attachment-restore-pins/`. The profile-media markers use its `profile-media/candidate/` subpath.
Exclude the current objects under `attachment-restore-pins/` from expiry for as long as the
corresponding object history can be restored. These markers preserve the decision to protect the
accepted file even after a PostgreSQL restore rolls back its metadata.

`ansible/roles/backup/tests/e2e.sh` covers PostgreSQL backup and restore with SOPS 3.13.3 and a
disposable S3 endpoint. It exercises recovery of deleted objects on a versioned application bucket
and Task membership recovery, including failure before cutover and interrupted recovery.

To replay the Storage API end to end, build the test runner and point it at a locally built
Storage image. Run the following from this repository with `storage-service:local` replaced by
your local Storage image. Load the pinned PostgreSQL, SeaweedFS, NATS and NATS CLI images listed
in the test scripts into the local Docker engine before running the recipe.

```sh
docker build -t cadenway-backup-e2e:local \
  -f ansible/roles/backup/tests/Dockerfile ansible/roles/backup
storage_image=$(docker image inspect --format '{{.Id}}' storage-service:local)
docker run --rm --init --network none \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/ansible/roles/backup:/backup:ro" \
  -e CADENWAY_E2E_PREPARED=1 \
  -e "CADENWAY_E2E_STORAGE_IMAGE=$storage_image" cadenway-backup-e2e:local
```

This mode verifies the production migrations, single-use multipart transfers for attachments,
intake and avatars, API completion, encrypted dump, deletion, restore, and downloads after Storage
restarts. Two concurrent avatar transfers must produce a single S3 version. The recipe also
compares restored bytes and S3 versions and repeats the restore to check that it creates no extra
versions. The test uses synthetic data in disposable containers that share the runner's loopback
network. CI runs the default backup suite without the Storage image input.

NATS JetStream streams, Meilisearch indexes and Traefik certificates are not backed up: the outbox
replays events, search-service rebuilds its index, Let's Encrypt issues certificates again.

## Limits to know

- A change to `compose/infra.yaml` or `compose/edge.yaml` reaches every host at once, with a restart
  of the changed container (PostgreSQL included): merge such changes at a quiet time.
- Public candidates keep their edge endpoint while starting. Traefik can route to each healthy
  candidate before the application batch is committed.
- The agent checks a failed commit once. To retry it unchanged, delete
  `/var/lib/cadenway-agent/<env>/failed` on the host.
- A secret value cannot contain a single quote (`'`): env files carry values literally between
  single quotes. The agent refuses such a commit and says which variable.
