# Domain and integration

[Documentation index](README.md) · [Repository instructions](../AGENTS.md)

**Status:** This page records the target design from repository instructions and skills. Its behavior has not been verified as implemented in this snapshot.

## Operational boundaries

Terraform owns OVH infrastructure, Ansible prepares the host, Compose describes services, and the GitOps agent is intended to pull desired state. Do not read state, decrypted environment files, private keys, or secret values. The repository's [AGENTS.md](../AGENTS.md) controls which checks are allowed; deployment, infrastructure mutation, and access to real hosts are not implied by this document. The procedures below describe the intended design and are not an active production runbook.

## Terraform Conventions

Source: `cw-terraform-conventions` ([Claude](../.claude/skills/cw-terraform-conventions/SKILL.md), [Codex](../.codex/skills/cw-terraform-conventions/SKILL.md)).

- `versions.tf` pins Terraform and the OVH provider.
- Backend: Object Storage bucket with locking.
- Modules: `vps`, `dns`, `storage`; outputs: VPS address and bucket names for Ansible.

## Ansible Conventions

Source: `cw-ansible-conventions` ([Claude](../.claude/skills/cw-ansible-conventions/SKILL.md), [Codex](../.codex/skills/cw-ansible-conventions/SKILL.md)).

- Roles: `base`, `docker`, `agent`, `backup`; playbooks `setup.yml`, `backup.yml`, `restore.yml`.
- `defaults/main.yml` documents every variable; secrets come from encrypted variables.
- Every task named; `changed_when` set for commands; no shell when a module exists.

## Compose Layout

Source: `cw-compose-layout` ([Claude](../.claude/skills/cw-compose-layout/SKILL.md), [Codex](../.codex/skills/cw-compose-layout/SKILL.md)).

| File                         | Holds                                                                                                    |
| ---------------------------- | -------------------------------------------------------------------------------------------------------- |
| `compose/compose.yaml`       | `include:` of `infra.yaml` and `../services/*.yaml`                                                      |
| `compose/infra.yaml`         | Traefik, PostgreSQL (one database per service from `postgres/init/`), Redis, NATS JetStream, Meilisearch |
| `compose/compose.local.yaml` | `build: ../../cadenway-<x>` with `develop.watch`, MinIO, Mailpit, `DOMAIN=cadenway.localhost`            |
| `services/<service>.yaml`    | copied from each service's `deploy/compose.yaml`                                                         |

Local start: `docker compose -f compose.yaml -f compose.local.yaml --profile core up -d` from `compose/`.

## Gitops Agent

Source: `cw-gitops-agent` ([Claude](../.claude/skills/cw-gitops-agent/SKILL.md), [Codex](../.codex/skills/cw-gitops-agent/SKILL.md)).

1. `git fetch`; exit if the commit is unchanged.
2. Diff `versions.env` and `services/` with the last applied commit: list changed services.
3. Decrypt `secrets.sops.env` into `/run/cadenway/`.
4. For each changed service: `pull`, run migrations in a one-off container, start the new instance
   beside the old one, wait up to 60 s for `healthy`, stop the old one.
5. Failure: keep the old instance, record the commit as failed, alert; do not retry that commit.
6. Notify: service, version, commit, duration, result.

## References

[Interactive mockup](https://claude.ai/artifact/KYRM7AnsYLiBLBLKy8i4HE), [integration guide](https://claude.ai/artifact/CpJHVCiFfF9j3KbHQ2S1Et), and [repositories and packages](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N). Use [AGENTS.md](../AGENTS.md) as the local source for ownership and hard limits.
