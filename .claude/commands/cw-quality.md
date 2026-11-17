---
description: "Run the static checks, stopping at the first failure."
allowed-tools: Read, Bash(pnpm format:check), Bash(docker compose --env-file compose/.env.example -f compose/compose.yaml -f compose/compose.local.yaml --profile full config -q), Bash(docker compose -f compose/edge.yaml config -q), Bash(docker compose -p cadenway-staging --env-file compose/.env.example --env-file environments/staging/versions.env -f compose/compose.yaml config -q), Bash(docker compose -p cadenway-prod --env-file compose/.env.example --env-file environments/prod/versions.env -f compose/compose.yaml config -q), Bash(yamllint --strict .), Bash(ansible-lint ansible/), Bash(ansible-playbook -i ansible/inventory/hosts.example.yml --syntax-check ansible/playbooks/*.yml), Bash(terraform -chdir=terraform fmt -check), Bash(terraform -chdir=terraform validate), Bash(shellcheck agent/cadenway-agent.sh agent/tests/e2e.sh ansible/tests/run.sh ansible/roles/backup/files/cadenway-backup.sh ansible/roles/backup/files/cadenway-restore.sh ansible/roles/backup/tests/e2e.sh)
---

Run the [full local gate](../../docs/development.md#full-local-quality-gate) from this checkout. Follow its order and
stop at the first failure. Report passed, failed, not run or unavailable for each check and
explain gaps. For targeted work, use the [minimum checks](../../AGENTS.md#commands-and-quality-gates).
Use only the local example inputs listed in the gate. Compose validation does not start the stack.
