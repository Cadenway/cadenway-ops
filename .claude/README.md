# waypoint-ops: Claude Code tooling

This `.claude/` folder ships the Claude Code tooling of waypoint-ops: **12 agents**,
13 slash commands, 9 rules, 17 skills, 3 hooks, the project
settings.

Start from [AGENTS.md](../AGENTS.md) (the rules every assistant follows) and [CLAUDE.md](../CLAUDE.md)
(the Claude entry point).

## Settings (`settings.json`)

- **Hooks** are wired through `${CLAUDE_PROJECT_DIR}` so they resolve from any working directory:
  `guard.mjs` before every `Write` / `Edit` / `MultiEdit`, `guard-git.mjs` before every `Bash` /
  `PowerShell` command, and `format.mjs` after matching edit events for supported files.
  Apply the repository rules across tools.
- **Permissions** allow specific repository commands and read-only Git commands. The project
  denies `Read` on `.env` and `.env.*`. Follow the repository secret-handling rules across tools.
  The project does not pre-approve `git push`, `gh` writes or arbitrary shell commands.
- **Fast mode is off** (`fastMode: false` and `CLAUDE_CODE_DISABLE_FAST_MODE=1`). Agent models and
  efforts are explicit in each agent's frontmatter; do not silently substitute a model.
- **MCP**: `enabledMcpjsonServers` enables `context7` from the root `.mcp.json`.
- **No plugins** are enabled (`enabledPlugins: {}`). The folder is itself a plugin
  (`.claude-plugin/plugin.json`, `hooks/hooks.json`) for installations outside this checkout.

## Working with the sibling repositories

Start from this checkout and attach the peers you need, for example:

```powershell
claude --add-dir ../waypoint-api-gateway ../waypoint-task-service ../waypoint-webapp
```

Their `.claude/agents/` are discovered too, so their `wp-*` roles become available. Peer checkouts
are **read-only** from a waypoint-ops session (the guard refuses edits there): change them in their
own session and pull request.

## Agents

Builders write only assigned files, inherit permissions and preserve concurrent work. Reviewers are
read-only: their tools exclude `Edit` and `Write`, and they ask the parent for the output of any
check that writes files. No agent delegates further.

| Agent | Responsibility | Model | Effort | Mode |
| --- | --- | --- | --- | --- |
| `wp-ops-compose-builder` | Compose files, networks, profiles, local overrides. | sonnet | high | Assigned writes |
| `wp-ops-traefik-maintainer` | Entry points, certificates, middlewares. | sonnet | high | Assigned writes |
| `wp-ops-ansible-role-builder` | Idempotent roles and playbooks. | opus | high | Assigned writes |
| `wp-ops-terraform-builder` | OVH resources. | opus | high | Assigned writes |
| `wp-ops-agent-maintainer` | The GitOps sync script. | opus | xhigh | Assigned writes |
| `wp-ops-secrets-steward` | SOPS process, never values. | sonnet | medium | Assigned writes |
| `wp-ops-backup-restore-builder` | Backups and tested restores. | opus | high | Assigned writes |
| `wp-ops-observability-builder` | Logs, metrics, traces, uptime. | sonnet | high | Assigned writes |
| `wp-ops-runbook-writer` | Operating procedures. | sonnet | medium | Assigned writes |
| `wp-ops-deploy-reviewer` | Desired-state changes. | opus | high | Read-only |
| `wp-ops-security-auditor` | Hardening, exposure, secrets. | opus | xhigh | Read-only |
| `wp-ops-github-maintainer` | Workflows, templates and community files in .github/. | sonnet | medium | Assigned writes |

## Commands

| Command | What it does | Runs |
| --- | --- | --- |
| `/wp-compose` | Change Compose files, networks or profiles. | `wp-ops-compose-builder` |
| `/wp-traefik` | Change Traefik routing or security. | `wp-ops-traefik-maintainer` |
| `/wp-ansible` | Write or change an Ansible role or playbook. | `wp-ops-ansible-role-builder` |
| `/wp-terraform` | Change OVH resources in Terraform. | `wp-ops-terraform-builder` |
| `/wp-agent` | Change the GitOps sync script. | `wp-ops-agent-maintainer` |
| `/wp-secrets` | Change the secret inventory or SOPS rules (never values). | `wp-ops-secrets-steward` |
| `/wp-backup` | Build backups and restore tests. | `wp-ops-backup-restore-builder` |
| `/wp-observability` | Add logs, metrics, traces or alerts. | `wp-ops-observability-builder` |
| `/wp-runbook` | Write a runbook. | `wp-ops-runbook-writer` |
| `/wp-deploy-review` | Review a desired-state change. | `wp-ops-deploy-reviewer` |
| `/wp-security-review` | Audit hardening and secrets. | `wp-ops-security-auditor` |
| `/wp-github` | Change workflows, templates or community files in .github/. | `wp-ops-github-maintainer` |
| `/wp-quality` | Run the static checks, stopping at the first failure. | runs the commands itself |

## Rules

| File | Subject | Loads for |
| --- | --- | --- |
| `compose.md` | Docker Compose | `compose/**`, `services/**` |
| `environments.md` | Environments | `environments/**` |
| `ansible.md` | Ansible | `ansible/**` |
| `terraform.md` | Terraform | `terraform/**` |
| `agent.md` | GitOps agent | `agent/**` |
| `language.md` | Language | always |
| `git-and-commits.md` | Git and commits | always |
| `comments.md` | Comments and docblocks | `**/*.yml`, `**/*.yaml`, `**/*.tf`, `agent/**` |
| `github.md` | GitHub files | `.github/**` |

## Skills

See [skills/](skills/) for the complete inventory, including the technology guides.

| Skill | Use |
| --- | --- |
| `wp-context` | What Waypoint is, where the mockup, the integration guide and the repository map live, the product vocabulary (spaces, lists, sprints, tasks, statuses, milestones) and the multi-repository ownership rules. |
| `wp-compose-layout` | How the Compose files of waypoint-ops fit together for production and local development, with networks, profiles and domains. |
| `wp-gitops-agent` | What the agent on the VPS does on each run and how it rolls out, verifies and keeps the old version on failure. |
| `wp-ansible-conventions` | Role layout, idempotency, variables and hardening baseline for waypoint-ops. |
| `wp-terraform-conventions` | Provider pinning, state backend, module layout and outputs for waypoint-ops. |

## Hooks

| Hook | When | What it refuses or does |
| --- | --- | --- |
| `guard.mjs` | before `Write`, `Edit` or `MultiEdit` | Sibling checkouts, generated trees, lockfiles, `.git/`, secrets and tokens, decrypted secrets, unencrypted SOPS files, Terraform state and keys, unpinned third-party actions and `pull_request_target` in workflows. |
| `guard-git.mjs` | before `Bash` or `PowerShell` | Pushes to `main`, tag pushes, force-pushes, rewrites of pushed commits, hook bypasses, destructive resets, registry publishing, branch names outside `<type>/<kebab>`. Adapted from the dentalstock guard. |
| `format.mjs` | after a successful `Write`, `Edit` or `MultiEdit` | Formats supported files with the repository's Prettier (and `terraform fmt` for `.tf`); a no-op until the formatter is installed. |
