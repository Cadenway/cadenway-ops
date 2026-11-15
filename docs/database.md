# PostgreSQL databases and roles

[Documentation index](README.md) · [Environments](../environments/README.md) · [Deployment](deployment.md)

One PostgreSQL per environment (`compose/infra.yaml`) holds one database per service. Nothing is
shared: a service only connects to its own database.

## Two roles per service

`compose/postgres/init/10-service-databases.sh` creates, for the service `<service>` (`identity`,
`organization`, `billing`, `task`, `document`, `storage`, `notification`, `automation`,
`integration`, `search`):

| Role                 | Used by                                                  | May                                                                                                                |
| -------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `<service>_migrator` | The one-off migration container (`node dist/migrate.js`) | Everything in its database, which it owns: it runs the DDL                                                         |
| `<service>_app`      | The running service                                      | Connect, then `SELECT`, `INSERT`, `UPDATE` and `DELETE` on the tables, and use the sequences, the migrator creates |

The application role owns nothing, holds no `CREATE` right on the database or on a schema, cannot
create a temporary table, and has neither `SUPERUSER` nor `BYPASSRLS`: the row-level security
policies of the tables apply to it, and it cannot switch them off. It gets its rights on a table when
the migrator creates it, through default privileges, in every schema the migrator creates (the
`pgboss` schema of the jobs included). That covers the migration journal of Drizzle too: the
application role could change its rows, never the structure it describes.

Neither role can connect to the database of another service: `CONNECT` is revoked from `PUBLIC` on
each of them.

## Variables

| Variable of the stack                   | Holds                                                 | Read as, in the service container |
| --------------------------------------- | ----------------------------------------------------- | --------------------------------- |
| `<NAME>_DB_MIGRATOR_PASSWORD`           | Password of `<service>_migrator`, given to PostgreSQL | Not passed to a service           |
| `<NAME>_DB_APP_PASSWORD`                | Password of `<service>_app`, given to PostgreSQL      | Not passed to a service           |
| `<NAME>_SERVICE_DATABASE_URL`           | URL of the application role, with its password        | `DATABASE_URL`                    |
| `<NAME>_SERVICE_MIGRATION_DATABASE_URL` | URL of the migrator, with its password                | `MIGRATION_DATABASE_URL`          |

`<NAME>` is the service in capitals (`TASK`). `compose/.env.example` holds the local values; staging
and production keep the four of each service in `secrets.sops.env`
(see [environments](../environments/README.md#secrets)).

The GitOps agent applies the migrations in a one-off container of the service, before it starts the
new version (see [deployment](deployment.md)). That container has the environment of the service
definition, so the definition carries both URLs. The service reads `DATABASE_URL`;
`src/migrate.ts` reads `MIGRATION_DATABASE_URL`. A service whose `src/migrate.ts` still reads
`DATABASE_URL` cannot apply a migration: the application role is refused, the agent keeps the
previous version and reports the commit as failed.

Locally nothing applies the migrations at start-up. Once the definition of a service carries
`MIGRATION_DATABASE_URL`, apply them with the command the agent runs:

```bash
docker compose run --rm --no-deps task-service node dist/migrate.js
```

## Timeouts

Set on each role by the init script, not per query. A session may lower or raise them for one
transaction (`SET LOCAL`).

| Role                 | `statement_timeout` | `lock_timeout` | `idle_in_transaction_session_timeout` |
| -------------------- | ------------------- | -------------- | ------------------------------------- |
| `<service>_app`      | 10 s                | 5 s            | 30 s                                  |
| `<service>_migrator` | 15 min              | 5 s            | 60 s                                  |

A statement of the application never outlives the 10 s budget of a request. A migration may build
an index for minutes, but gives up after 5 s on a lock: a DDL statement that waits for one blocks
every query queued behind it, so it fails and the deployment is tried again.

The roles carry no connection limit. Each service opens a pool of 5 connections and, with jobs, 2
more; PostgreSQL keeps its default of 100.

## Bringing an existing volume up to date

The image runs the init script once, when the data volume is empty. The script is idempotent: a
later run creates what is missing, sets the passwords, the privileges and the timeouts again, and
keeps the data. Run it by hand after a change to the script, for a new service, or after a password
changed:

```bash
# Locally, from compose/, once compose/.env has the variables of .env.example:
docker compose up -d postgres
docker compose exec postgres sh /docker-entrypoint-initdb.d/10-service-databases.sh
```

`docker compose up -d postgres` recreates the container when its variables changed, so the script
sees the new passwords.

A volume created before the two roles has one `<service>` role that owns each database. The run
gives what it owned to `<service>_migrator`, grants the application role its rights on the existing
tables of `public`, and drops the former role. Starting again from nothing works too:
`docker compose down --volumes` deletes the local data of every infrastructure service.

On a host, an operator runs the same script in the PostgreSQL container of the environment, after
the GitOps agent applied the commit that changed the secrets (the agent recreates the container
with the new variables, it does not run the script):

```bash
docker exec "$(docker ps -q --filter label=com.docker.compose.project=cadenway-<env> \
  --filter label=com.docker.compose.service=postgres)" \
  sh /docker-entrypoint-initdb.d/10-service-databases.sh
```

Rotating a database password is therefore two steps: change the password and the URL that carries
it in `secrets.sops.env` and merge; then run the script. Between the two, the service keeps its
open connections and new ones are refused.

## Backup and restore

The nightly backup dumps each database as the superuser. A restore creates the database again for
`<service>_migrator`, lets `<service>_app` connect, and restores the dump as the migrator: the
rights of the application role on the tables, and the default privileges, come back from the dump
(see [deployment](deployment.md#backups)).

## Checks

`compose/tests/postgres-roles.sh` starts the PostgreSQL of `compose/infra.yaml` as a throwaway
project and proves the above against it; CI runs it on every pull request.
