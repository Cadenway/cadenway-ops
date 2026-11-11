---
name: wp-terraform-conventions
description: "Provider pinning, state backend, module layout and outputs for waypoint-ops. Load it before changing Terraform."
---

# Terraform conventions

- `versions.tf` pins Terraform and the OVH provider.
- Backend: Object Storage bucket with locking.
- Modules: `vps`, `dns`, `storage`; outputs: VPS address and bucket names for Ansible.
