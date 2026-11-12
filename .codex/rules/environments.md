---
paths:
  - 'environments/**'
---

# Environments

- `versions.env`: one `<SERVICE>_VERSION` per deployable, written by the deploy bot; human edits only
  to roll back.
- `services/`: the definitions this environment runs, written by the deploy bot with the version.
- `secrets.sops.env`: encrypted with SOPS and age; edit with `sops`, never write plaintext. No single
  quote in a value.
- `environments/prod/` requires an approval (CODEOWNERS).
