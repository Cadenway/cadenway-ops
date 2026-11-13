# Development and verification

[Documentation index](README.md) · [Repository overview](../.github/README.md) · [Repository instructions](../AGENTS.md)

## Bootstrap status

The Compose stack (local and server), the shared edge Traefik, the Ansible roles and playbooks, the GitOps agent with its end-to-end test, and the CI exist in this checkout. Terraform and `seed/` do not exist yet. Nothing has been applied to a real host: see [deployment](deployment.md) for the operator steps.

The commands below are the documented **target workflow**, copied from the repository overview and instructions. They are not proof that scripts, infrastructure, CI, or dependencies currently exist. Inspect the repository's actual manifests and files before running them, and report unavailable checks rather than inventing replacements. Run Git, pnpm, build, and test commands with this repository as the working directory, never from the parent workspace.

## Before making a change

- `environments/<env>/versions.env` and `compose/compose.yaml` before any deployment change.
- `ansible/roles/<role>/` before changing the machine.
- The [repositories document](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N), sections "Exploitation" and "Déploiement".

## Local setup

Clone this repository next to the other Cadenway repositories, flat, in one folder: the local
stack builds each service from its sibling folder.

```bash
cd compose
cp .env.example .env              # once
docker compose up -d              # start (stop: docker compose down)
docker compose watch task-service # rebuild a service when its sources change
```

`compose/.env` sets Compose's own `COMPOSE_FILE` and `COMPOSE_PROFILES`, so the plain commands use
the local overrides and the `core` profile; set `COMPOSE_PROFILES=full` there for every service.

The `core` profile starts the infrastructure, the identity, task and notification services, the API
gateway and the web application: open `http://app.cadenway.localhost`, and
`http://mail.cadenway.localhost` for the e-mails the stack sends (Mailpit). The `full` profile adds
Garage, the local object store: its S3 API answers on `http://s3.cadenway.localhost`, with the
placeholder key and bucket of `compose/.env.example`. Terraform runs only
from its GitHub Action; the Terraform and Ansible credentials never live in this repository.

## Minimum checks by change

The scripts below are this repository's contract. While the repository is being bootstrapped,
create them with these exact names; afterwards, use them and never an ad-hoc equivalent. Run the
narrowest check that covers the change first, then widen:

| Changed                         | Minimum check                                                                                                   |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Compose or Traefik              | `docker compose … config -q`, `yamllint .`                                                                      |
| Ansible                         | `ansible-lint ansible/`, `ansible-playbook --syntax-check`, then `--check` on a staging host when the user asks |
| Terraform                       | `terraform fmt -check`, `terraform validate`; `plan` only when the user asks                                    |
| Agent script                    | `shellcheck agent/*.sh`                                                                                         |
| Environments                    | `docker compose … config -q` with the environment's `versions.env`                                              |
| Docs or agent instructions only | Scoped formatting and link review                                                                               |

Report the commands you actually ran and their results; a check you did not run is reported as not
run.

## Planned full check list

The following commands match the planned local gate. Run `/cw-quality` in Claude Code or
`$cw-quality` in Codex without arguments. Verify CI coverage once workflows exist.

```bash
docker compose -f compose/compose.yaml -f compose/compose.local.yaml config -q
yamllint .
ansible-lint ansible/
ansible-playbook --syntax-check ansible/playbooks/setup.yml
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
shellcheck agent/*.sh
```

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
