# cadenway-ops documentation

Planned role: cadenway-ops is the whole operation of Cadenway: what exists at OVH (Terraform), how the VPS is prepared (Ansible), and what runs in each environment (Docker Compose files, service definitions, versions and encrypted secrets read by the GitOps agent). It is also where local development starts the stack.

## Current status

The Compose stack (local and server), the shared edge Traefik, the Ansible roles and playbooks, the GitOps agent with its end-to-end test, and the CI exist in this checkout. Terraform and `seed/` do not exist yet. Nothing has been applied to a real host: see [deployment](deployment.md) for the operator steps.

## Read the guides

- [Architecture and ownership](architecture.md): boundaries and planned repository structure.
- [Development and checks](development.md): prerequisites, planned commands and verification.
- [Deployment and operations](deployment.md): release path, topologies, host setup, backups.
- [Domain and integration](integration.md): repository-specific contracts, behavior and dependencies.

## Sources and policy

- [Repository overview](../.github/README.md) and [contribution guide](../.github/CONTRIBUTING.md).
- [Repository instructions and hard limits](../AGENTS.md).
- [Claude Code instructions](../CLAUDE.md) and [tooling](../.claude/README.md).
- [Codex tooling](../.codex/README.md).
- [Interactive mockup](https://claude.ai/artifact/KYRM7AnsYLiBLBLKy8i4HE), [integration guide](https://claude.ai/artifact/CpJHVCiFfF9j3KbHQ2S1Et), and [repositories and packages](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N).

Repository instructions take precedence over this summary. Refer to the actual package manifests, implementation, specifications, and workflows once they exist; do not infer a deployed feature from a target design.
