---
paths:
  - 'environments/**'
---

# Environments

- `versions.env`: one `<SERVICE>_VERSION` per deployable, written by the deploy bot; human edits only
  to roll back.
- `secrets.sops.env`: encrypted with SOPS and age; edit with `sops`, never write plaintext.
- `environments/prod/` requires an approval (CODEOWNERS).
