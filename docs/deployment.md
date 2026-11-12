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
   it), starts the new container beside the old one, waits up to 60 s for `healthy` and removes the
   old one.
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

It holds the agent's lock throughout (no deployment meanwhile), checks each dump before touching
anything, then drops and recreates the database before restoring it, so tables added by later
migrations do not survive next to an older migration journal. `ansible/roles/backup/tests/e2e.sh`
covers backup and restore against a real PostgreSQL in CI.

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
