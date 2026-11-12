---
name: cw-tech-terraform
description: "Author or review Cadenway OVH Terraform configuration and infrastructure changes."
---

# Terraform for Cadenway

Work in `cadenway-ops`, read its Terraform conventions and existing configuration, and restrict changes to the requested infrastructure. Never read or edit state, secret values, decrypted files, keys, or generated `.terraform` content. Run the repository's format and validate checks if prerequisites are available; run a plan only when explicitly requested. Apply and destroy are not agent-shell actions under the repository rules.

Consult the official documentation for the version actually used: https://developer.hashicorp.com/terraform/docs.
