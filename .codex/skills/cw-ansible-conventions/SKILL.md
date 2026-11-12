---
name: cw-ansible-conventions
description: "Role layout, idempotency, variables and hardening baseline for cadenway-ops. Load it before writing a role."
---

# Ansible conventions

- Roles: `base`, `docker`, `agent`, `backup`; playbooks `setup.yml`, `backup.yml`, `restore.yml`.
- `defaults/main.yml` documents every variable; secrets come from encrypted variables.
- Every task named; `changed_when` set for commands; no shell when a module exists.
