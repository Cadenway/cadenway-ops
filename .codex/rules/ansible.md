---
paths:
  - 'ansible/**'
---

# Ansible

- Idempotent, named tasks; handlers for restarts; `defaults/` documented.
- Hardening: SSH keys only, no root login, firewall 80/443/SSH, fail2ban, unattended upgrades.
- Validate changed playbooks locally with `--syntax-check` and the example inventory. Run `--check`
  against a staging host only when asked. Agents never apply a playbook to a real host.
