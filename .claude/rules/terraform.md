---
paths:
  - 'terraform/**'
---

# Terraform

- OVH provider pinned; state in Object Storage with locking; `apply` only from the GitHub Action.
- Typed, described variables; outputs feed the Ansible inventory.
- `terraform fmt` and `validate` before every change.
