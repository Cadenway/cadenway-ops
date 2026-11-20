# Environment of the backends

[Documentation index](README.md) · [Environments](../environments/README.md) · [Development](development.md)

What each backend reads from its environment, where the value comes from, and what its
`deploy/compose.yaml` has to declare. The variables are those of `@cadenway/nest-common`
(configuration, internal token, internal HTTP client, database) and of the infrastructure of this
repository.

A service definition may only use `environment` (its deploy workflow refuses `command`,
`entrypoint`, `volumes` and `secrets`), so everything below reaches a container as an environment
variable.

## Where a value comes from

A definition writes either a literal or `${VARIABLE}`. Compose resolves the variable from:

| Source                                            | Holds                                                                                                                        | Locally                                      |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `/etc/cadenway/env/<env>.env`, written by Ansible | Public settings: `DOMAIN`, `PUBLIC_SCHEME`, `GHCR_OWNER`, `NATS_URL`, `REDIS_URL`, `MEILI_URL`, the ten `<NAME>_SERVICE_URL` | `compose/.env`, copied from `.env.example`   |
| `environments/<env>/versions.env`                 | `<NAME>_VERSION`                                                                                                             | `compose/.env`                               |
| `environments/<env>/secrets.sops.env`             | Everything secret or specific to the environment                                                                             | `compose/.env`; the token keys are generated |

The GitOps agent refuses a commit that leaves a variable unset. A definition that reads a new
variable is therefore released after the variable exists on the host: the secret merged, or
`ansible/playbooks/setup.yml` applied for a public setting.

## Internal token

Every call between backends carries a token signed by the caller with its own Ed25519 key and
checked by the called service against the keys of the issuers it trusts.

| Issuer                | Calls                              | Its key pair in the stack                                                          |
| --------------------- | ---------------------------------- | ---------------------------------------------------------------------------------- |
| `api-gateway`         | every service                      | `API_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK`, `API_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS` |
| `realtime-gateway`    | identity-service, task-service     | `REALTIME_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK`, `…_PUBLIC_JWKS`                     |
| `automation-service`  | task-service, notification-service | `AUTOMATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK`, `…_PUBLIC_JWKS`                   |
| `integration-service` | task-service                       | `INTEGRATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK`, `…_PUBLIC_JWKS`                  |

- `<NAME>_INTERNAL_TOKEN_PRIVATE_JWK` is one line of JSON, a secret, read by that issuer only, as
  `INTERNAL_TOKEN_PRIVATE_JWK`.
- `<NAME>_INTERNAL_TOKEN_PUBLIC_JWKS` is the public key as one line of JSON; several keys separated
  by commas during a rotation. A called service builds `INTERNAL_TOKEN_TRUSTED_ISSUERS` from the
  public keys of the issuers it trusts, in its own definition: who a service trusts is reviewed in
  the repository of that service.

```yaml
INTERNAL_TOKEN_AUDIENCE: task-service
INTERNAL_TOKEN_TRUSTED_ISSUERS: >-
  {"api-gateway": [${API_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS}],
  "realtime-gateway": [${REALTIME_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS}],
  "automation-service": [${AUTOMATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS}],
  "integration-service": [${INTEGRATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS}]}
```

The folded scalar (`>-`) gives the service one line of JSON.

### Keys of a workstation

No private key is committed, not even a development one. Once, after `cp .env.example .env`:

```bash
docker compose run --rm internal-token-keys
```

The container runs `compose/internal-token/generate-keys.mjs`, which appends the four key pairs to
`compose/.env` (never committed). Compose then reads them like any other variable, exactly as it
reads the secrets on a host. A second run changes nothing; to replace a pair, delete its two lines
and run it again. Without the keys, Compose warns that the variables are not set and the backends
refuse to start, naming `INTERNAL_TOKEN_PRIVATE_JWK` or `INTERNAL_TOKEN_TRUSTED_ISSUERS`.

### Keys of staging and production

An operator generates them and puts them in the secrets, each environment with its own:

```bash
docker compose run --rm internal-token-keys --print   # eight lines, on the terminal only
sops edit environments/staging/secrets.sops.env       # paste them
```

To rotate the key of an issuer: add the new public key to its `…_PUBLIC_JWKS` after a comma and
merge; replace its `…_PRIVATE_JWK` and merge; then remove the old public key.

## What each definition declares

Every backend keeps what it has today (`PORT`, and `DATABASE_URL`, `NATS_URL` or `REDIS_URL`).
`NODE_ENV`, `LOG_LEVEL` and `LOG_PRETTY` have defaults fit for a server and stay unset.
`OTEL_EXPORTER_OTLP_ENDPOINT` stays unset until an environment has a collector.

### Every service

`<name>` is the service without `-service` (`task`), `<NAME>` the same in capitals.

| Variable                         | Value in `deploy/compose.yaml`                                       |
| -------------------------------- | -------------------------------------------------------------------- |
| `NATS_USER`                      | `<name>` ([messaging](messaging.md))                                 |
| `NATS_PASSWORD`                  | `${<NAME>_NATS_PASSWORD}`                                            |
| `INTERNAL_TOKEN_AUDIENCE`        | `<name>-service`                                                     |
| `INTERNAL_TOKEN_TRUSTED_ISSUERS` | The JSON above, with the issuers of the service (see the next table) |

`MIGRATION_DATABASE_URL` is not declared: the GitOps agent gives it, from
`<NAME>_SERVICE_MIGRATION_DATABASE_URL` of the secrets, to the one-off container that runs the
migrations, and to no other ([database](database.md)). A definition that still declares it keeps
working, but its running container then holds the credentials that own its schema: each service
removes the line from its `deploy/compose.yaml`.

### Per backend

| Backend              | Trusts                                                                         | Also declares                                                                                                                                                                                                                                                                                                                                                      |
| -------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| identity-service     | `api-gateway`, `realtime-gateway`                                              | `PASSWORD_PEPPER: ${IDENTITY_PASSWORD_PEPPER}`, the secret its keys derive from, kept outside the database; `WEBAUTHN_RP_ID: app.${DOMAIN}`, `WEBAUTHN_ORIGINS: ${PUBLIC_SCHEME:-https}://app.${DOMAIN}`, the relying party of its security keys                                                                                                                   |
| organization-service | `api-gateway`                                                                  |                                                                                                                                                                                                                                                                                                                                                                    |
| billing-service      | `api-gateway`                                                                  |                                                                                                                                                                                                                                                                                                                                                                    |
| task-service         | `api-gateway`, `realtime-gateway`, `automation-service`, `integration-service` |                                                                                                                                                                                                                                                                                                                                                                    |
| document-service     | `api-gateway`                                                                  |                                                                                                                                                                                                                                                                                                                                                                    |
| storage-service      | `api-gateway`                                                                  | `S3_ENDPOINT`, `S3_PUBLIC_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_FORCE_PATH_STYLE`, each from `${STORAGE_S3_…}`                                                                                                                                                                                                      |
| notification-service | `api-gateway`, `automation-service`                                            | `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `MAIL_FROM`, each from the variable of the same name; `WEB_APP_URL: ${PUBLIC_SCHEME:-https}://app.${DOMAIN}`, the origin of the links in its e-mails                                                                                                                                                       |
| automation-service   | `api-gateway`                                                                  | `INTERNAL_TOKEN_ISSUER: automation-service`, `INTERNAL_TOKEN_PRIVATE_JWK: ${AUTOMATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK}`, `TASK_SERVICE_URL`, `NOTIFICATION_SERVICE_URL`                                                                                                                                                                                        |
| integration-service  | `api-gateway`                                                                  | `INTERNAL_TOKEN_ISSUER: integration-service`, `INTERNAL_TOKEN_PRIVATE_JWK: ${INTEGRATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK}`, `TASK_SERVICE_URL`                                                                                                                                                                                                                  |
| search-service       | `api-gateway`                                                                  | `MEILI_URL: ${MEILI_URL}`, `MEILI_API_KEY: ${MEILI_MASTER_KEY}`                                                                                                                                                                                                                                                                                                    |
| api-gateway          | nobody: it authenticates the applications itself                               | `ALLOWED_ORIGINS: ${PUBLIC_SCHEME:-https}://app.${DOMAIN},${PUBLIC_SCHEME:-https}://${DOMAIN}`, `INTERNAL_TOKEN_ISSUER: api-gateway`, `INTERNAL_TOKEN_PRIVATE_JWK: ${API_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK}`, the ten `<NAME>_SERVICE_URL`; `NATS_URL`, `NATS_USER: api-gateway`, `NATS_PASSWORD: ${API_GATEWAY_NATS_PASSWORD}` once it publishes its usage event |
| realtime-gateway     | nobody: it authenticates the sockets itself                                    | `ALLOWED_ORIGINS: ${PUBLIC_SCHEME:-https}://app.${DOMAIN}`, `INTERNAL_TOKEN_ISSUER: realtime-gateway`, `INTERNAL_TOKEN_PRIVATE_JWK: ${REALTIME_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK}`, `IDENTITY_SERVICE_URL`, `TASK_SERVICE_URL`, `NATS_USER: realtime-gateway`, `NATS_PASSWORD: ${REALTIME_GATEWAY_NATS_PASSWORD}`                                                 |

`ALLOWED_ORIGINS` lists, comma-separated, the exact origins a browser may call a gateway from: CORS
and the CSRF check of the API gateway read it. The API gateway accepts the web application and the
public site; the realtime gateway, which only the web application opens, accepts the web
application. Both values are built from `PUBLIC_SCHEME` and `DOMAIN`, so no environment sets it.

`WEBAUTHN_RP_ID` is the relying-party id of the security keys identity-service registers, to which
a browser binds each key: the host of the web application, `app.${DOMAIN}`. A browser lets a page
ask only for the keys of its own host or of a parent domain, so no other page under the domain, the
web application of staging (`app.staging.cadenway.com`) included, can ask for a key of production
(`app.cadenway.com`): the keys of staging and production stay apart. The id is final once keys
exist: changing it makes every registered key unusable. `WEBAUTHN_ORIGINS` lists, comma-separated,
the exact origins a key may be registered or used from, the web application only, and
identity-service still checks the origin of every answer against it exactly. Both values come from
`DOMAIN` and `PUBLIC_SCHEME`, like `ALLOWED_ORIGINS`, so no environment sets them and a host needs
nothing new.

`PASSWORD_PEPPER` is kept outside the database of identity-service. The service derives from it,
each with its own HKDF-SHA-256 label, the secret key of the password hashes and the key of the code
hashes. The two-step verification release of identity-service adds two derivations, the key that
encrypts the authenticator-app secrets and the key of the backup code hashes; the releases before it
have neither. Changing the pepper makes every stored password and pending code unusable, and, from
that release, every authenticator app and backup code too: there is no rotation.

A `<NAME>_SERVICE_URL` is declared as `${<NAME>_SERVICE_URL}`: `http://<name>-service:<port>` on the
internal network, the same in every environment.

`S3_ENDPOINT` is where the service reaches the object storage; `S3_PUBLIC_ENDPOINT` is the host the
browser follows in a signed URL. They differ on a workstation only (`http://garage:3900` and
`http://s3.cadenway.localhost`).

Before deploying an attachment-enabled Storage image, provision `STORAGE_UPLOAD_RECEIPT_KEYS`
through the environment's encrypted configuration. Install the CORS policy for the application's
exact origin on the files bucket. The Storage identity also needs the bucket-level `s3:ListBucket`
permission for the `org/` prefix so reconciliation can find attachment writes that arrive after
cleanup. Keep that grant scoped to the environment's files bucket and keep the existing object
permissions scoped to its attachment keys.

`compose/compose.local.yaml` repeats these entries for the local stack, which runs the definitions
of the last release with images built from the sources: keep the two in step. It also gives each
service `MIGRATION_DATABASE_URL`, from the placeholders of `compose/.env.example`, so that
`docker compose run --rm --no-deps <service> node dist/migrate.js` applies the migrations on a
workstation: the one exception to the rule above ([database](database.md)).

## Secrets

Besides those of the [database](database.md#variables) and of the
[broker](messaging.md#secrets), `secrets.sops.env` of each environment holds:

| Variable                                                                                                                                                                                   | Used by                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------- |
| `API_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK`, `REALTIME_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK`, `AUTOMATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK`, `INTEGRATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK` | the issuer named by the variable |
| `API_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS`, `REALTIME_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS`, `AUTOMATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS`, `INTEGRATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS` | the services that trust it       |
| `IDENTITY_PASSWORD_PEPPER`                                                                                                                                                                 | identity-service                 |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `MAIL_FROM`                                                                                                                        | notification-service             |
| `STORAGE_S3_ENDPOINT`, `STORAGE_S3_PUBLIC_ENDPOINT`, `STORAGE_S3_REGION`, `STORAGE_S3_BUCKET`, `STORAGE_S3_ACCESS_KEY_ID`, `STORAGE_S3_SECRET_ACCESS_KEY`, `STORAGE_S3_FORCE_PATH_STYLE`   | storage-service                  |
| `STORAGE_UPLOAD_RECEIPT_KEYS`                                                                                                                                                             | attachment-enabled storage-service |

The public keys are not secret; they sit with the private ones so that an environment's keys are
edited in one place. JSON values need no quoting in the file: the agent writes each value between
single quotes, and a JSON Web Key contains none.

## Checks

`compose/tests/service-wiring.sh` generates keys in a temporary folder, checks that they sign and
verify, and checks the environment Compose builds for each backend; CI runs it on every pull
request.
