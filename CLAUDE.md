# cadenway-ops: Claude Code instructions

> **Source of truth.** This file is the entry point for Claude Code. The normative rules live in
> [AGENTS.md](AGENTS.md), imported below: read it, do not paraphrase it from memory.

@AGENTS.md

> **Read on demand, deliberately not `@`-imported**: the [repositories document](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N), sections "Exploitation", "Déploiement", "Avant la production". Importing them would
> cost context in every session. The path-scoped rules in `.claude/rules/` load automatically when
> you open a matching file and carry the few things that must never be got wrong there.

## TL;DR for every task

1. Three levels: Terraform creates OVH resources (VPS, DNS zone, Object Storage buckets), Ansible prepares the VPS, the GitOps agent deploys what `environments/<env>/` describes.
2. The VPS runs Docker Compose; Traefik is the only exposed container (`app.`, `www.`, `api.`, `realtime.`, Let's Encrypt); services stay on the `internal` network.
3. One PostgreSQL with one database and one user per service; Redis, NATS JetStream, Meilisearch beside it; files and backups in OVH Object Storage.
4. Secrets are encrypted with SOPS and age, in Git; only the VPS key decrypts them. Never write a decrypted secret, never read the key.
5. Versions in `environments/<env>/versions.env` are written by the deploy bot; `environments/prod/` and `terraform/` need an approval.
6. Local development uses the same Compose files with `compose.local.yaml` (sibling folders built, Mailpit, `*.localhost` domains; the local object store comes with the storage service).

## Boundaries (hard rules)

- No application code here; service definitions in `environments/<env>/services/` are copied from each service's `deploy/compose.yaml` by its deploy workflow.
- No plaintext secret, private key, state file or decrypted `.env` in the repository.
- Terraform runs only from the GitHub Action; Ansible playbooks are idempotent.
- Nothing opens an inbound path to the VPS for deployments: the agent pulls.

## Target quality gate

Use the [minimum checks by change](docs/development.md#minimum-checks-by-change) first.
Run `/cw-quality` without arguments for the full local gate when applicable. Report unavailable
checks during bootstrap.

```bash
docker compose -f compose/compose.yaml -f compose/compose.local.yaml config -q
yamllint .
ansible-lint ansible/
ansible-playbook --syntax-check ansible/playbooks/setup.yml
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
shellcheck agent/*.sh
```

Commands that change a server or OVH (`ansible-playbook` without `--check`, `terraform apply`) are never run by an agent.

## Tooling: this repository ships its own `.claude/`

Open `cadenway-ops/` as the workspace root to activate it. The `cw-ops-*` agents, the `/cw-*`
commands, the skills and the hooks are described in [.claude/README.md](.claude/README.md). Two things
the session listing does not tell you:

- **Rules** in `.claude/rules/` load at session start unless they declare `paths`. Scoped rules
  load when Claude reads a matching file.
- **Hooks** cover the edit and shell tool events matched in `.claude/settings.json`.
  `guard.mjs` refuses edits that break a hard rule
  (generated trees, lockfiles, secrets, sibling checkouts, decrypted secrets, unencrypted SOPS files, Terraform state and keys, unpinned third-party actions and `pull_request_target` in workflows), `guard-git.mjs`
  refuses pushes to `main`, tag pushes, force-pushes, rewrites of pushed commits, hook bypasses and
  registry publishing, and `format.mjs` formats supported files when its formatter is available.
  Apply the repository rules across tools. Resolve a refusal without bypassing the hook.

The sibling repositories (`../cadenway-api-gateway`, `../cadenway-task-service`, `../cadenway-webapp`, `../cadenway-billing-service`) are read-only references
from here; add them to the session (`--add-dir`) when a task needs to read them.
