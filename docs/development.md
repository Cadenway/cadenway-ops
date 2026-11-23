# Development and verification

[Documentation index](README.md) · [Repository overview](../.github/README.md) · [Repository instructions](../AGENTS.md)

## Bootstrap status

The Compose stack (local and server), the shared edge Traefik, the Ansible roles and playbooks, the GitOps agent with its end-to-end test, and the CI exist in this checkout. Terraform and `seed/` do not exist yet. Nothing has been applied to a real host: see [deployment](deployment.md) for the operator steps.

Run Git, pnpm, build, and test commands with this repository as the working directory. The
[full local quality gate](#full-local-quality-gate) lists the commands available in this checkout
and the checks that apply when Terraform files are present.

## Before making a change

- `environments/<env>/versions.env` and `compose/compose.yaml` before any deployment change.
- `ansible/roles/<role>/` before changing the machine.
- The [repositories document](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N), sections "Exploitation" and "Déploiement".

## Local setup

Clone this repository next to the other Cadenway repositories, flat, in one folder: the local
stack builds each service from its sibling folder.

```bash
cd compose
cp .env.example .env                        # once
docker compose run --rm internal-token-keys # once: the key pairs of the internal token
docker compose up -d                        # start (stop: docker compose down)
docker compose watch task-service           # rebuild a service when its sources change
```

`compose/.env` sets Compose's own `COMPOSE_FILE` and `COMPOSE_PROFILES`, so the plain commands use
the local overrides and the `core` profile; set `COMPOSE_PROFILES=full` there for every service.

A second stack can run beside the first one, to check a branch for example, under another project
name and Traefik port: `TRAEFIK_HTTP_PORT=8080 docker compose -p cadenway-check up -d`. It has its
own volumes, its own edge network (`<project>-edge-local`) and a Traefik that serves the containers
of its own project only, so neither Traefik routes to the other stack
(`compose/tests/local-isolation.sh`). A stack started before this rule runs a Traefik that still
reads every project: `docker compose up -d` in it first recreates that Traefik. Reach the second
stack with `curl` or the API on its port (`http://api.cadenway.localhost:8080`): the addresses it
publishes carry no port, so its web application, its allowed origins and the links of its e-mails
still name the first stack. Both stacks build the same image names
(`ghcr.io/local/cadenway-<x>:local`): a stack runs the image last built by either one when its
containers are next created.

The backends sign their calls to each other with Ed25519 keys, and no private key is committed:
`internal-token-keys` generates the pairs of this workstation into `compose/.env`. See
[environment of the backends](service-environment.md) for these keys and for every variable a
backend receives.

The images install the private `@cadenway/*` packages, so their build needs to read GitHub
Packages. Compose passes the `NPMRC` environment variable to each build as a secret: one line of
user-level npmrc, mounted for the install steps only. Set it in the shell that runs Compose, never
in a file of this repository:

```bash
export NPMRC="//npm.pkg.github.com/:_authToken=$(gh auth token)"
```

Without it the build stops on `401 Unauthorized` when pnpm fetches the first Cadenway package.

The `core` profile starts the infrastructure, the identity, organization, task and notification
services, the API gateway and the web application: open `http://app.cadenway.localhost`, and
`http://mail.cadenway.localhost` for the e-mails the stack sends (Mailpit). The `full` profile adds
Garage, the local object store: its S3 API answers on `http://s3.cadenway.localhost`, with the
placeholder key and bucket of `compose/.env.example`. Terraform applies through GitHub Actions.
The Terraform and Ansible credentials are managed outside this repository.

To exercise one-shot uploads locally, select `STORAGE_UPLOAD_TRANSFER_MODE=local-one-shot`,
set `STORAGE_UPLOAD_TRANSFER_URL` to the example URL in `compose/.env.example` and use a Storage
build with the one-shot migration applied. The local
Traefik exposes only the multipart transfer path on the `upload` host. Downloads continue to use
the Garage endpoint. Run one Storage replica in this mode. A restart invalidates outstanding
transfer tickets. If the transfer result is uncertain, check completion first and request a
fresh reservation when the existing transfer cannot be completed.

## Minimum checks by change

Use the [checks by change in AGENTS.md](../AGENTS.md#commands-and-quality-gates) to select and report the smallest applicable verification.

## Full local quality gate

Run these steps from the repository root. The same procedure backs `/cw-quality` in Claude Code
and `$cw-quality` in Codex.

Run these examples in Bash. For the Compose checks, use a checkout and shell without live
environment files or values. Compose resolves only the checked-in placeholders and version files.
Record any missing-variable warnings in the check result. A successful configuration check
verifies the Compose definitions before runtime credentials are supplied.

```bash
pnpm format:check
docker compose --env-file compose/.env.example -f compose/compose.yaml -f compose/compose.local.yaml --profile full config -q
ACME_EMAIL=ci@example.com docker compose -f compose/edge.yaml config -q
```

Validate the staging and production definitions with their version files.

```bash
ENVIRONMENT=staging CADENWAY_SERVICES=../environments/staging/services \
  docker compose -p cadenway-staging --env-file compose/.env.example \
  --env-file environments/staging/versions.env -f compose/compose.yaml config -q
ENVIRONMENT=prod CADENWAY_SERVICES=../environments/prod/services \
  docker compose -p cadenway-prod --env-file compose/.env.example \
  --env-file environments/prod/versions.env -f compose/compose.yaml config -q
```

For the operations checks, use the same example inventory and shell files as CI.

```bash
yamllint --strict .
ansible-playbook -i ansible/inventory/hosts.example.yml --syntax-check ansible/playbooks/*.yml
ansible-lint ansible/
shellcheck agent/cadenway-agent.sh agent/tests/e2e.sh ansible/tests/run.sh \
  ansible/roles/backup/files/cadenway-backup.sh ansible/roles/backup/files/cadenway-restore.sh \
  ansible/roles/backup/tests/e2e.sh ansible/roles/backup/tests/storage_e2e.sh \
  ansible/roles/backup/tests/task_membership_e2e.sh \
  ansible/roles/backup/tests/real_task_membership_e2e.sh
```

When `terraform/` exists, use `terraform -chdir=terraform fmt -check` and
`terraform -chdir=terraform validate` with the required providers available. Report missing
tools, collections, providers, or files as unavailable.

## Collaboration and release

- Trunk-based: work branches come from `main`, named `<type>/<lowercase-kebab-description>` with a
  type among `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`,
  `revert`; put the Cadenway task id first when there is one (`feat/cad-482-sso-screen`). Never an
  agent name as a prefix. Validate with `git check-ref-format --branch <name>`.
- Commits and PR titles follow Conventional Commits: `type(scope): subject`, English, imperative,
  lowercase subject, no trailing period, at most 100 characters; `!` only for a breaking change.
- Pull requests target `main` and are squash-merged after review and green CI. Not versioned: every merge to `main` is the new desired state. Bot commits update `environments/staging/` automatically and `environments/prod/` after the approval in the service repository.
- Stage only the files of your task; preserve other people's changes in the working tree.

Keep credentials, private keys, decrypted environment files and Terraform state out of documentation and logs. Follow the hard limits in [AGENTS.md](../AGENTS.md); setup instructions do not authorize deployments or changes to real infrastructure.

### Local telemetry

The local stack starts an OpenTelemetry Collector on its internal network. Backend export is off
by default. Before enabling it, each backend must use a released `@cadenway/nest-common` version
that supports `CADENWAY_OTEL_REDACT_HTTP_QUERY_STRINGS`. Local Compose sets that option to `true`
for every backend. Once that version is installed, set `OTEL_EXPORTER_OTLP_ENDPOINT` to
`http://otel-collector:4318` in the local environment to export traces and metrics over OTLP/HTTP.

The collector logs signal summaries for local diagnostics and does not retain telemetry. Its health
check probes the collector's local health endpoint. The hosted environments do not use this collector.

Run `bash compose/tests/otel-collector.sh` to build the collector in an isolated Compose project
and verify that it receives and exports a trace and a metric. The test removes its project afterward.
