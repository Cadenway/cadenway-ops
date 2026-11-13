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

| File                                         | Holds                                                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `compose/edge.yaml`                          | the one Traefik of a host (80, 443, Let's Encrypt) and the networks `cadenway-edge-staging`, `cadenway-edge-prod` |
| `compose/compose.yaml`                       | one environment: `include:` of `infra.yaml` and `${CADENWAY_SERVICES:-../environments/staging/services}/*.yaml`   |
| `compose/infra.yaml`                         | PostgreSQL (one database per service from `postgres/init/`), Redis, NATS JetStream, Meilisearch                   |
| `compose/compose.local.yaml`                 | local Traefik, `build: ../../cadenway-<x>` with `develop.watch`, Mailpit, Garage, `DOMAIN=cadenway.localhost`     |
| `environments/<env>/services/<service>.yaml` | copied from each service's `deploy/compose.yaml` by its deploy workflow                                           |

Local start, from `compose/`: `cp .env.example .env` once, then `docker compose up -d`; `compose/.env` sets
`COMPOSE_FILE` and `COMPOSE_PROFILES` (`core`, or `full` for every service).

## Gitops Agent

Source: `cw-gitops-agent` ([Claude](../.claude/skills/cw-gitops-agent/SKILL.md), [Codex](../.codex/skills/cw-gitops-agent/SKILL.md)).

1. Fetch `main`; apply `compose/edge.yaml` when the commit changed; skip a commit already applied or
   already failed.
2. Decrypt `secrets.sops.env` into `/run/cadenway/<env>/`; refuse a commit that leaves a variable unset.
3. For each deployable whose fingerprint changed or whose container is not healthy: `pull`, run
   migrations in a one-off container, start the new instance beside the old one, wait up to 60 s for
   `healthy`, remove the old one.
4. Failure of the desired state: keep the old instance, record the commit as failed, alert; do not
   retry that commit. Transient failure: retry every minute, alert once.
5. Notify: environment, commit, duration, result.

## References

[Interactive mockup](https://claude.ai/artifact/KYRM7AnsYLiBLBLKy8i4HE), [integration guide](https://claude.ai/artifact/CpJHVCiFfF9j3KbHQ2S1Et), and [repositories and packages](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N). Use [AGENTS.md](../AGENTS.md) as the local source for ownership and hard limits.
