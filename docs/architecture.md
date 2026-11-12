# Architecture and ownership

[Documentation index](README.md) · [Repository instructions](../AGENTS.md)

## Status

The Compose stack (local and server), the shared edge Traefik, the Ansible roles and playbooks, the GitOps agent with its end-to-end test, and the CI exist in this checkout. Terraform and `seed/` do not exist yet. Nothing has been applied to a real host: see [deployment](deployment.md) for the operator steps.

The following architecture is the target recorded in [AGENTS.md](../AGENTS.md). Paths and integrations are design boundaries, not evidence that files or services already exist.

## Purpose and target structure

cadenway-ops is the whole operation of Cadenway: what exists at OVH (Terraform), how the VPS is prepared (Ansible), and what runs in each environment (Docker Compose files, service definitions, versions and encrypted secrets read by the GitOps agent). It is also where local development starts the stack.

```text
terraform/        ← VPS, DNS zone, Object Storage; state in Object Storage, locked
ansible/          ← inventory, roles (base, docker, agent, backup), playbooks (setup, backup, restore)
compose/          ← compose.yaml, infra.yaml, edge.yaml (one Traefik per host), compose.local.yaml, postgres/init/
environments/     ← staging/ and prod/: services/ (definitions), versions.env, secrets.sops.env
agent/            ← sync script, systemd timer and its end-to-end test
seed/             ← mockup data for staging and local
```

## Architectural ownership

- `terraform/`: OVH resources only.
- `ansible/`: machine configuration only.
- `compose/`: shared infrastructure services and local overrides.
- `environments/`: the desired state the agent applies.
- `agent/`: the sync script (pull, decrypt, migrate, roll out, health check, alert).

## Boundaries

- No application code here; service definitions in `environments/<env>/services/` are copied from each service's `deploy/compose.yaml` by its deploy workflow.
- No plaintext secret, private key, state file or decrypted `.env` in the repository.
- Terraform runs only from the GitHub Action; Ansible playbooks are idempotent.
- Nothing opens an inbound path to the VPS for deployments: the agent pulls.

## Cross-repository changes

Each checkout owns its implementation and release. Use published `@cadenway/*` packages instead of sibling source imports or local dependency links. For contract changes, make the contract and generated package available first, then update the producing service, gateways and listeners, and finally the webapp. Each step should remain deployable independently.
