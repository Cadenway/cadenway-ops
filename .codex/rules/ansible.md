---
paths:
  - 'ansible/**'
---

# Ansible

- Idempotent, named tasks; handlers for restarts; `defaults/` documented.
- Hardening: SSH keys only, no root login, firewall 80/443/SSH, fail2ban, unattended upgrades.
- Never run a playbook against a real host from an agent; `--syntax-check` and `--check` only when asked.
