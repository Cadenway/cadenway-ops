# cadenway-ops: agent instructions

These shared instructions apply to every assistant. Explicit user instructions take precedence over
procedures within the hard limits below. Claude Code imports this file through [CLAUDE.md](CLAUDE.md).

## First read

- Before a deployment change, read `environments/<env>/versions.env` and `compose/compose.yaml`.
  Before changing the host, read the relevant `ansible/roles/<role>/`.
- Use the [repositories document](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N) sections
  "Exploitation", "Déploiement" and "Avant la production" as needed.

## What this repository is

This repository owns OVH infrastructure, host configuration, environment definitions, GitOps
rollout and the local stack. Use the [ownership map](docs/architecture.md#architectural-ownership)
for directory boundaries. Check the checkout before relying on the bootstrap target.

## Language

- Everything written in the repository is **English**: code, comments, docs, agent prompts, rules,
  skills, commit messages, branch names, PR titles and descriptions.
- Follow the user's language in the conversation only. No emojis.
- Never invent facts about the product, the contracts, the mockup or the tooling: cite the file or
  the document. When something does not exist yet, say so and say which step of the start-up plan
  brings it.

## Architectural ownership

- Use the [deployment guide](docs/deployment.md) for pull-based rollout, edge routing and topology.
  Traefik is the only exposed container. The apex and its `www.` redirect, `app.`, `api.` and
  `realtime.` use Let's Encrypt. Services otherwise stay on the internal network.
- Use the [database guide](docs/database.md) for the shared PostgreSQL host and service-owned
  databases and roles. Use `cw-compose-layout` for Redis, JetStream, Meilisearch and local
  Compose overrides (sibling builds, Mailpit, localhost domains and Garage in the full profile).
  Production files and backups use OVH Object Storage.
- Keep environment secrets SOPS/age encrypted in Git. Only the VPS key decrypts them.
  The deploy bot writes versions. Preserve the CODEOWNERS approval for `environments/prod/` and
  `terraform/`.

## Boundaries (hard rules)

- No application code here; service definitions in `environments/<env>/services/` are copied from each service's `deploy/compose.yaml` by its deploy workflow.
- No plaintext secret, private key, state file or decrypted `.env` in the repository.
- Terraform applies through GitHub Actions. Ansible playbooks are idempotent.
- Nothing opens an inbound path to the VPS for deployments: the agent pulls.

## GitHub files (`.github/`)

Keep this repository's [README](.github/README.md), community files, templates, code owners and
complete workflows in `.github/`. Cadenway has no organization-level files, cross-repository
reusable workflows or shared Renovate preset. Use the paired `github.md` rules when editing
GitHub files. Apply changes to shared material through separate pull requests in each owner.

## Code quality

- Read the affected entry point, its callers, and its relevant tests before editing.
  Preserve the behavior callers rely on unless the task changes it.
- Keep the diff focused. Use names that express intent and reuse existing code when
  it preserves the required behavior. Extract code when it clarifies a responsibility.
- Keep business decisions with their owning module. Validate external inputs at the
  boundary and use documented public interfaces across modules and repositories.
- For writes that can fail, overlap, or be retried, verify the resulting state.
  Check transaction boundaries, tenant scope, and repeated delivery where relevant.
- For collections and repeated work, check what grows with input size. Measure or
  inspect the bottleneck before adding an index, cache, worker, or replica.
- Run the repository checks that cover the affected behavior. Report the commands
  and their results, including checks that did not run and tests that selected zero cases.

## Commands and quality gates

Start with the smallest check that covers the change. See the
[full local gate](docs/development.md#full-local-quality-gate) for the repository-wide sequence.

| Changed                         | Minimum check                                                                                                   |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Compose or Traefik              | `docker compose … config -q` with the gate's example inputs, `yamllint --strict .`                              |
| Ansible                         | `ansible-lint ansible/`, `ansible-playbook --syntax-check`, then `--check` on a staging host when the user asks |
| Terraform                       | `terraform fmt -check`, `terraform validate`; `plan` only when the user asks                                    |
| Agent script                    | `shellcheck agent/*.sh`                                                                                         |
| Environments                    | `docker compose … config -q` with the environment's `versions.env`                                              |
| Docs or agent instructions only | Scoped formatting and link review                                                                               |

## Git and branch flow

Use the paired `git-and-commits.md` rule for trunk-based branches, Conventional Commits and
staging only task files. Validate branch names with `git check-ref-format --branch <name>`.

Pull requests target `main` and are squash-merged after review and green CI. Each merge becomes
the desired state. Bot commits update staging automatically and production after service-side
approval. See [collaboration and release](docs/development.md#collaboration-and-release).

## Hard limits (never without the user's explicit request in this conversation)

- Never push to `main`, merge into it locally, create or push Git tags, or bump a version by hand.
- Never run a registry publish (`npm publish`, `pnpm publish`): this repository ships as a Docker image built by CI.
- Never force-push, and never amend or rebase commits that are already pushed.
- Never bypass the Git hooks (`--no-verify`, `core.hooksPath` overrides, `ALLOW_MAIN_PUSH=1`,
  `CW_SKIP_PUSH_CHECKS=1`).
- Never write a token, password or private key anywhere. Do not read or write secret environment
  files; new variables are documented in `.env.example`.
- Never edit generated trees (`dist/`, `node_modules/`, `coverage/`, `.terraform/`, `*.tfstate`) or lockfiles by hand.
- Never modify a sibling checkout (`../cadenway-*`) from a task in this repository.
- Never run `terraform apply`, `terraform destroy`, `ansible-playbook` against a real host (without `--check`) or `docker compose up` on a server.
- Never decrypt a secret file to disk, never print a decrypted value, never read an age key.

The agent hooks enforce most of these mechanically; a refused command is a signal to stop and ask,
not to find another way around it.

## Agent tooling

Use the [Claude](.claude/README.md#agents) or [Codex](.codex/README.md) guide for specialists,
commands, skills, scoped rules and hooks. Read the active assistant's matching rules for every
touched path and load skills relevant to the task. Specialists are available when needed.
Give each delegate a bounded assignment, owning checkout, explicit files and checks. Keep
parallel write scopes disjoint and integrate the results.

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

Use the [documentation index](docs/README.md#sources-and-policy) for the mockup, integration
guide and repositories document.
