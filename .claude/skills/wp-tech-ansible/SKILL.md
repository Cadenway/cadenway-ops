---
name: wp-tech-ansible
description: "Author or review idempotent Ansible roles and playbooks for the Waypoint VPS."
---

# Ansible for Waypoint

Work in `waypoint-ops`, inspect the relevant role, inventory structure, and Ansible conventions without reading secret material. Prefer idempotent tasks, explicit handlers, and minimal changes. Run lint and syntax checks where available; run check mode on a staging host only when requested. Never run a mutating playbook against a real host from an agent shell.

Consult the official documentation for the version actually used: https://docs.ansible.com/.
