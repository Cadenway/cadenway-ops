# Environments

Each folder is the desired state of one environment, applied by the GitOps agent of the host that
runs it (see [deployment](../docs/deployment.md)).

| File               | Written by                                | Holds                                                                          |
| ------------------ | ----------------------------------------- | ------------------------------------------------------------------------------ |
| `services/`        | the deploy workflow of each service (bot) | the definitions this environment runs; local development runs the staging ones |
| `versions.env`     | the deploy workflow of each service (bot) | `<DEPLOYABLE>_VERSION=1.4.0`, one per line                                     |
| `secrets.sops.env` | an operator, with `sops`                  | the secrets below, encrypted with SOPS and age                                 |

A deployable without a line in `versions.env` is not started. A human edits `versions.env` only to
roll back; the deploy workflow of the service (`workflow_dispatch` with the older version) does the
same with a reviewed commit.

The public settings of an environment (domain, scheme, image owner) are not here: Ansible writes
them on the host from `ansible/inventory/group_vars/cadenway.yml`.

## Secrets

`secrets.sops.env` is a dotenv file encrypted value by value. It holds:

| Variable                                                        | Used by                        |
| --------------------------------------------------------------- | ------------------------------ |
| `POSTGRES_PASSWORD`                                             | PostgreSQL superuser           |
| `<NAME>_DB_PASSWORD`, one per service database                  | `compose/postgres/init`        |
| `<NAME>_SERVICE_DATABASE_URL`, with the same password           | each service                   |
| `MEILI_MASTER_KEY`                                              | Meilisearch and search-service |
| `ALERT_WEBHOOK_URL` (optional, Slack-compatible)                | the agent's notifications      |
| `GHCR_PULL_USER`, `GHCR_PULL_TOKEN` (optional, `read:packages`) | the agent, for private images  |
| `BACKUP_S3_ENDPOINT`, `BACKUP_S3_REGION`, `BACKUP_S3_BUCKET`    | the nightly backup             |
| `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY`        | the nightly backup             |

Values are taken literally; a value cannot contain a single quote (`'`).

The stack variables match [`compose/.env.example`](../compose/.env.example), which holds the local
values.

## SOPS recipients

Only the hosts that run an environment, and the operators, can decrypt it. Create `.sops.yaml` at
the repository root once the age recipients are known (the setup playbook prints each host's):

```yaml
creation_rules:
  - path_regex: environments/staging/secrets\.sops\.env$
    age: >-
      age1<staging host>,
      age1<operator>
  - path_regex: environments/prod/secrets\.sops\.env$
    age: >-
      age1<production host>,
      age1<operator>
```

When staging and production share one VPS, the same host recipient appears in both rules. Then:

```bash
sops edit environments/staging/secrets.sops.env
sops updatekeys environments/prod/secrets.sops.env
```

`sops updatekeys` re-encrypts a file after a recipient is added or removed, for example when a host
is replaced.
