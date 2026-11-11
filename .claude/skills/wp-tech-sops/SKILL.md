---
name: wp-tech-sops
description: "Review SOPS and age configuration or encrypted-secret handling in Waypoint operations without exposing secrets."
---

# Sops for Waypoint

Work only on the requested non-secret configuration or documentation in `waypoint-ops`, following its secret-handling and GitOps instructions. Never read, decrypt, print or write secret values, private keys, decrypted environment files, or Terraform state. Verify only safe metadata and syntax using the repository's approved commands; do not execute rotation, deployment, or writes to real environments without explicit authorization.

Consult the official documentation for the version actually used: https://github.com/getsops/sops.
