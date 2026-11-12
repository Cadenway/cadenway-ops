# cadenway-ops

cadenway-ops is the whole operation of Cadenway: what exists at OVH (Terraform), how the VPS is prepared (Ansible), and what runs in each environment (Docker Compose files, service definitions, versions and encrypted secrets read by the GitOps agent). It is also where local development starts the stack.

```text
terraform/        ← VPS, DNS zone, Object Storage; state in Object Storage, locked
ansible/          ← inventory, roles (base, docker, agent, backup), playbooks (setup, backup, restore)
compose/          ← compose.yaml, infra.yaml, edge.yaml (one Traefik per host), compose.local.yaml, postgres/init/
environments/     ← staging/ and prod/: services/ (definitions), versions.env, secrets.sops.env
agent/            ← sync script, systemd timer and its end-to-end test
seed/             ← mockup data for staging and local
```

## Getting started

Clone this repository next to the other Cadenway repositories, flat, in one folder: the local
stack builds each service from its sibling folder.

```bash
cd compose
docker compose -f compose.yaml -f compose.local.yaml --profile core up -d
```

Then open `http://app.cadenway.localhost`. The `core` profile starts the infrastructure, the identity,
task and notification services and the API gateway; `full` starts everything. Terraform runs only
from its GitHub Action; the Terraform and Ansible credentials never live in this repository.

## Checks

Run the narrowest check first; CI runs them all on every pull request.

```bash
docker compose -f compose/compose.yaml -f compose/compose.local.yaml config -q
yamllint .
ansible-lint ansible/
ansible-playbook --syntax-check ansible/playbooks/setup.yml
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
shellcheck agent/*.sh
```

## Contributing

- [Contributing guide](CONTRIBUTING.md): branches, commits, pull requests, releases.
- [Code of conduct](CODE_OF_CONDUCT.md), [security policy](SECURITY.md), [getting help](SUPPORT.md).
- AI assistants follow [AGENTS.md](../AGENTS.md); Claude Code also reads [CLAUDE.md](../CLAUDE.md) and the
  tooling described in [.claude/README.md](../.claude/README.md).

## License

This repository is proprietary. See [LICENSE](../LICENSE) for the rights and restrictions that apply.

## References

- [Interactive mockup](https://claude.ai/artifact/KYRM7AnsYLiBLBLKy8i4HE): every screen, state and interaction.
- [Integration guide](https://claude.ai/artifact/CpJHVCiFfF9j3KbHQ2S1Et): tokens, data shapes, component names.
- [Repositories and packages](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N): what each repository owns, deployment.
