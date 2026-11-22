# Deployment and operations

[Documentation index](README.md) · [Architecture](architecture.md) · [Environments](../environments/README.md)

## How a release reaches a server

1. A pull request merged on a service's `main` updates its release pull request (release-please).
2. Merging the release pull request tags `vX.Y.Z`; the service's `release.yml` builds the image
   `ghcr.io/<org>/cadenway-<service>:X.Y.Z` (linux/amd64) and calls its `deploy.yml`.
3. `deploy.yml` checks the service's `deploy/compose.yaml` (only the keys, image, networks and
   Traefik rules a Cadenway service needs: no volume, no privilege, no other domain), then commits to
   `cadenway-ops` `main` with the deploy app: the definition into
   `environments/staging/services/` (which local development runs too) and the version into
   `environments/staging/versions.env`. After a reviewer approves the
   `production` environment of the service, it writes `environments/prod/services/` and
   `environments/prod/versions.env`. Each environment runs its own copy: a staging release never
   changes what production runs.
4. On each host, the GitOps agent (`agent/cadenway-agent.sh`, a systemd timer every minute) fetches
   `main`, and for each environment it runs: decrypts the secrets into `/run`, refuses a commit that
   leaves a variable unset, brings the infrastructure up, then for each deployable whose fingerprint
   changed (image, environment, definition, mounted config contents) or whose container is not
   healthy, runs its migrations in a one-off container (`node dist/migrate.js` when the image has
   it), to which it gives the migrator URL of its database ([database](database.md#variables)),
   starts the new container beside the old one, waits up to 60 s for `healthy` and removes the old
   one.
5. The outcome of a commit, posted to `ALERT_WEBHOOK_URL`:
   - **applied**: with the duration;
   - **failed** when the desired state itself is wrong (unhealthy container, failed migration,
     missing variable, secrets this host cannot decrypt): the old containers keep serving, the commit
     is not retried, the next commit is;
   - **retrying** when the cause is transient (image not pullable yet, registry login, infrastructure
     slow to start, edge network missing): tried again every minute, said once. Other services of the
     environment still deploy.

Nothing connects to a host to deploy: the host pulls with a read-only deploy key.

Rollback: run the service's **Deploy** workflow by hand with the previous version. It writes the
older definition and version through the same path, staging then production. A newer deploy replaces
a production deploy still waiting for its approval.

## Topologies

The same files serve both; the inventory decides (`ansible/inventory/hosts.example.yml`).

| Topology                | Inventory                                                  | On the host                                                  |
| ----------------------- | ---------------------------------------------------------- | ------------------------------------------------------------ |
| One VPS per environment | two hosts, `cadenway_environments: [staging]` and `[prod]` | one Traefik (`cadenway-edge`), one stack (`cadenway-<env>`)  |
| One VPS for both        | one host, `cadenway_environments: [staging, prod]`         | one Traefik, two stacks side by side, each with its own data |

Traefik runs once per host from `compose/edge.yaml` and owns ports 80 and 443. It creates one edge
network per environment (`cadenway-edge-staging`, `cadenway-edge-prod`); the exposed services of an
environment join only theirs, so staging and production containers never share a network. Router,
service and network names carry the environment (`api-gateway-staging`), and each environment answers
on its own domain.

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

## GitHub settings the workflows rely on

| Where                                 | Setting                                                                                                   |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Organization variables                | `CADENWAY_DEPLOY_APP_CLIENT_ID`                                                                           |
| Each service repository, environments | `release`, `staging`, `production`, each limited to the `main` branch; required reviewers on `production` |
| The same three environments           | the environment secret `CADENWAY_DEPLOY_APP_PRIVATE_KEY`; never an organization or repository secret      |
| `cadenway-ops` `main` rules           | the deploy app may push (bypass), everyone else goes through a pull request                               |
| GHCR packages                         | public, or `GHCR_PULL_USER` and `GHCR_PULL_TOKEN` in the environment's secrets                            |

Limited to `main`, the environments keep the app key out of any workflow run from a pull request
branch: the key writes the desired state of every host.

## Backups

`cadenway-backup.timer` dumps every service database of every environment of the host each night
(`pg_dump --format=custom`), encrypts each dump to `cadenway_backup_age_recipient` and streams it to
`<bucket>/<env>/<timestamp>/<database>.dump.age`. Older backups (30 days) are deleted only after every
database was saved; a failure leaves them, fails the unit and posts to `ALERT_WEBHOOK_URL`. Run one now
with `ansible-playbook ansible/playbooks/backup.yml --limit <host>`.

A restore overwrites live data; the playbook asks for the environment twice and the backup private
key, which it removes from the host afterwards:

```bash
ansible-playbook ansible/playbooks/restore.yml --limit cadenway-prod \
  -e cadenway_restore_environment=prod -e cadenway_restore_confirm=prod \
  -e cadenway_restore_timestamp=20261112T030512Z \
  -e cadenway_restore_identity_file=~/.config/cadenway/backup.key
```

The restore holds the GitOps lock. It decrypts and restores the complete archive into a temporary
database before stopping the running application and its workers. When the live database exists,
its Drizzle migration history must match the archive. Use a backup compatible with the running
application version. The restore then switches the database names in one transaction and verifies
that the previously running containers become healthy. Containers already stopped stay stopped.
When several databases are requested, each is restored and switched independently.

After a successful switch, the former database remains under the reported
`cw_restore_previous_…` name with connections disabled. It consumes disk space until an operator
removes it after verification. If startup fails, the command attempts to return the former
database to its original name and restart the previous set of containers. A candidate that
served under the live name is retained under `cw_restore_failed_…` with connections disabled.
Inspect it for any writes accepted before rollback. Investigate a reported rollback failure
before restarting services manually.

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

`ansible/roles/backup/tests/e2e.sh` covers PostgreSQL backup and restore with SOPS 3.13.3 and a
disposable S3 endpoint. It exercises recovery of deleted objects on a versioned application bucket.

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

This mode verifies the production migrations, presigned uploads, API completion, encrypted dump,
deletion, restore, and downloads after Storage restarts. It compares the restored bytes and S3
versions and repeats the restore to check that it creates no extra versions. The test uses
synthetic data in disposable containers that share the runner's loopback network. CI runs the
default backup suite without the Storage image input.

NATS JetStream streams, Meilisearch indexes and Traefik certificates are not backed up: the outbox
replays events, search-service rebuilds its index, Let's Encrypt issues certificates again.

## Limits to know

- A change to `compose/infra.yaml` or `compose/edge.yaml` reaches every host at once, with a restart
  of the changed container (PostgreSQL included): merge such changes at a quiet time.
- During a rollout the internal Docker DNS already resolves the service name to the new container
  while it starts; Traefik only routes to healthy containers.
- The agent checks a failed commit once. To retry it unchanged, delete
  `/var/lib/cadenway-agent/<env>/failed` on the host.
- A secret value cannot contain a single quote (`'`): env files carry values literally between
  single quotes. The agent refuses such a commit and says which variable.
