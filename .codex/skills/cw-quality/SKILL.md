---
name: cw-quality
description: Run the static checks, stopping at the first failure.
---

Run in order and stop at the first failure: `docker compose -f compose/compose.yaml -f compose/compose.local.yaml config -q`, `yamllint .`, `ansible-lint ansible/`, `ansible-playbook --syntax-check ansible/playbooks/setup.yml`, `terraform -chdir=terraform fmt -check`, `terraform -chdir=terraform validate`, `shellcheck agent/*.sh`. A missing tool is reported as **not available**. Never run `terraform apply`, a real `ansible-playbook` or `docker compose up` on a server. End with one line per step: PASS, FAIL, not run or not available.
