# Contributing to cadenway-ops

Thank you for helping build Cadenway. This guide covers this repository; the rules that people and AI
assistants follow here are in [AGENTS.md](../AGENTS.md).

## Before you start

- **Link your work to a task.** Every change starts from a Cadenway task (`CAD-482`); its id goes in
  the branch name and in the pull request.
- What this repository owns, and what it must not touch, is in [AGENTS.md](../AGENTS.md).

## Local setup

Follow [Getting started](README.md#getting-started). `terraform plan` and real Ansible runs need credentials that are never shared through the repository.

## Branches

- `main` is the only long-lived branch. It is protected and receives squash-merged pull requests only.
- Work branches come from `main`: `<type>/<lowercase-kebab-description>`, with the task id first when
  there is one.

  ```text
  feat/cad-482-sso-screen
  fix/cad-517-status-flicker
  docs/contributing-guide
  ```

- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.

## Commits

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```text
type(scope): subject in the imperative, lowercase, no trailing period

Why the change is needed, in a few lines.

Refs: CAD-482
```

- English, at most 100 characters on the first line.
- `!` after the type only for a breaking change (`feat(api)!: …`), with a `BREAKING CHANGE:` footer.
- `Fixes: CAD-482` completes the task when the pull request is merged; `Refs: CAD-482` only links it.

## Pull requests

- Target `main`. Keep a pull request focused on one change; split refactors from behavior changes.
- Title in Conventional Commits form: it becomes the squash commit.
- Fill in the [template](PULL_REQUEST_TEMPLATE.md).
- An approving review from a code owner and green CI are required to merge.
- The author merges, with a squash merge, once approved.

## Changes across several repositories

Each repository ships alone. A change that crosses repositories lands in this order, each step only
adding to the previous one:

1. `cadenway-api-contracts`: the spec, then the published packages;
2. the service that produces the data or the event;
3. the gateways and the services that listen;
4. `cadenway-webapp`.

This repository receives the deployment definitions and versions written by each service's CI: change a service definition in its own repository (`deploy/compose.yaml`), never here.

Never import another repository's sources and never use a `file:` or `link:` dependency: use the
published `@cadenway/*` packages.

## Checks

```bash
docker compose -f compose/compose.yaml -f compose/compose.local.yaml config -q
yamllint .
ansible-lint ansible/
ansible-playbook --syntax-check ansible/playbooks/setup.yml
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
shellcheck agent/*.sh
```

The checks run in CI on every pull request; report in the pull request the ones you ran locally.

## Releases and deployment

This repository is not versioned: every merge to `main` is the new desired state, and the GitOps
agent on the VPS pulls it. `environments/staging/` is updated automatically by the services' deploy
workflows; `environments/prod/` and `terraform/` change only after an approval. Terraform runs only
from the GitHub Action.

## GitHub files

Everything under `.github/` belongs to this repository: workflows, templates, code owners and these
guides. The other Cadenway repositories keep their own copies; a change to a shared part (the code of
conduct, the security policy, the templates) is repeated in each of them through its own pull request.

## Security

Never commit a secret, a token or a private key. To report a vulnerability, follow
[SECURITY.md](SECURITY.md); never open a public issue for it.

## Conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
