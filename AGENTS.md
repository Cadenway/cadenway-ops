# waypoint-ops: agent instructions

These instructions are mandatory for every AI assistant working in this repository, whatever the
vendor. [CLAUDE.md](CLAUDE.md) imports them for Claude Code. Explicit user instructions take
precedence over procedures, never over the hard limits below.

This file states the **rules**. See the tooling guides for [Claude Code](.claude/README.md)
and [Codex](.codex/README.md) for agents, skills, commands and hooks.

## First read

- `environments/<env>/versions.env` and `compose/compose.yaml` before any deployment change.
- `ansible/roles/<role>/` before changing the machine.
- The [repositories document](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N), sections "Exploitation" and "Déploiement".

## What this repository is

The structure and workflows below describe the bootstrap target. Check the checkout for available files and commands.

waypoint-ops is the whole operation of Waypoint: what exists at OVH (Terraform), how the VPS is prepared (Ansible), and what runs in each environment (Docker Compose files, service definitions, versions and encrypted secrets read by the GitOps agent). It is also where local development starts the stack.

```text
terraform/        ← VPS, DNS zone, Object Storage; state in Object Storage, locked
ansible/          ← inventory, roles (base, docker, agent, backup), playbooks (setup, backup, restore)
compose/          ← compose.yaml, infra.yaml, compose.local.yaml, traefik/, postgres/init/
services/         ← one definition per service, copied by its CI on release
environments/     ← staging/ and prod/: versions.env, secrets.sops.env
agent/            ← sync script and systemd timer
seed/             ← mockup data for staging and local
```

## Language

- Everything written in the repository is **English**: code, comments, docs, agent prompts, rules,
  skills, commit messages, branch names, PR titles and descriptions.
- Follow the user's language in the conversation only. No emojis.
- Never invent facts about the product, the contracts, the mockup or the tooling: cite the file or
  the document. When something does not exist yet, say so and say which step of the start-up plan
  brings it.

## Architectural ownership

- `terraform/`: OVH resources only.
- `ansible/`: machine configuration only.
- `compose/`: shared infrastructure services and local overrides.
- `services/` and `environments/`: the desired state the agent applies.
- `agent/`: the sync script (pull, decrypt, migrate, roll out, health check, alert).

## Boundaries (hard rules)

- No application code here; service definitions in `services/` are copied from each service's `deploy/compose.yaml` by CI.
- No plaintext secret, private key, state file or decrypted `.env` in the repository.
- Terraform runs only from the GitHub Action; Ansible playbooks are idempotent.
- Nothing opens an inbound path to the VPS for deployments: the agent pulls.

## GitHub files (`.github/`)

This repository carries everything GitHub reads from it; Waypoint has no organization `.github`
repository and nothing is inherited.

- [`.github/README.md`](.github/README.md) is the repository home page; `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `SECURITY.md`, `SUPPORT.md`, `PULL_REQUEST_TEMPLATE.md`, `ISSUE_TEMPLATE/` and
  `CODEOWNERS` sit next to it.
- `.github/workflows/` holds this repository's complete CI, release workflows: no reusable
  workflow from another repository. The Renovate configuration is complete here too, with no shared
  preset.
- The parts shared with the other repositories are duplicated on purpose; a change to them is repeated
  in each repository through its own pull request.

## Commands and quality gates

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

## Git and branch flow

- Trunk-based: work branches come from `main`, named `<type>/<lowercase-kebab-description>` with a
  type among `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`,
  `revert`; put the Waypoint task id first when there is one (`feat/way-482-sso-screen`). Never an
  agent name as a prefix. Validate with `git check-ref-format --branch <name>`.
- Commits and PR titles follow Conventional Commits: `type(scope): subject`, English, imperative,
  lowercase subject, no trailing period, at most 100 characters; `!` only for a breaking change.
- Pull requests target `main` and are squash-merged after review and green CI. Not versioned: every merge to `main` is the new desired state. Bot commits update `environments/staging/` automatically and `environments/prod/` after the approval in the service repository.
- Stage only the files of your task; preserve other people's changes in the working tree.

## Hard limits (never without the user's explicit request in this conversation)

- Never push to `main`, merge into it locally, create or push Git tags, or bump a version by hand.
- Never run a registry publish (`npm publish`, `pnpm publish`): this repository ships as a Docker image built by CI.
- Never force-push, and never amend or rebase commits that are already pushed.
- Never bypass the Git hooks (`--no-verify`, `core.hooksPath` overrides, `ALLOW_MAIN_PUSH=1`,
  `WP_SKIP_PUSH_CHECKS=1`).
- Never write a token, password or private key anywhere; `.npmrc` keeps `${NODE_AUTH_TOKEN}`. Do
  not read or write secret environment files; new variables are documented in `.env.example`.
- Never edit generated trees (`dist/`, `node_modules/`, `coverage/`, `.terraform/`, `*.tfstate`) or lockfiles by hand.
- Never modify a sibling checkout (`../waypoint-*`) from a task in this repository.
- Never run `terraform apply`, `terraform destroy`, `ansible-playbook` against a real host (without `--check`) or `docker compose up` on a server.
- Never decrypt a secret file to disk, never print a decrypted value, never read an age key.

The agent hooks enforce most of these mechanically; a refused command is a signal to stop and ask,
not to find another way around it.

## Agent tooling

- **Claude Code**: [CLAUDE.md](CLAUDE.md) and [.claude/README.md](.claude/README.md): the
  `wp-ops-*` agents, the `/wp-*` commands (`/wp-quality` runs the whole local gate),
  path-scoped rules and hooks.
- **Codex**: [.codex/README.md](.codex/README.md) covers the specialists, `$wp-*` skills, rules and hooks.
- **Builders** (assigned writes): `wp-ops-compose-builder`, `wp-ops-traefik-maintainer`, `wp-ops-ansible-role-builder`, `wp-ops-terraform-builder`, `wp-ops-agent-maintainer`, `wp-ops-secrets-steward`, `wp-ops-backup-restore-builder`, `wp-ops-observability-builder`, `wp-ops-runbook-writer`, `wp-ops-github-maintainer`.
- **Reviewers** (read-only): `wp-ops-deploy-reviewer`, `wp-ops-security-auditor`.
- Specialists are available, not mandatory. Delegate a bounded responsibility with explicit files and
  checks, assign disjoint files to parallel agents and integrate their results yourself.

## Repository hygiene

- Reuse existing commands, tools and test infrastructure before adding files.
- Prefer inline commands or a task-specific temporary directory for one-off diagnostics; clean up
  disposable files before delivery.
- Keep a permanent script only when it provides a reusable capability that existing tooling cannot.
- Add permanent tests for meaningful behavior or regressions, in the existing test structure.
- Before delivery, inspect untracked files and remove only the disposable artifacts of the current
  task. Report every new permanent tooling file and why it needs to stay.
- Report material failures, skipped checks and limitations, including non-blocking ones. Ask for
  user input only when a missing decision or authorization blocks the dependent work.

## References

- [Interactive mockup](https://claude.ai/artifact/KYRM7AnsYLiBLBLKy8i4HE), [integration guide](https://claude.ai/artifact/CpJHVCiFfF9j3KbHQ2S1Et) and
  [repositories and packages](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N) (living documents).
