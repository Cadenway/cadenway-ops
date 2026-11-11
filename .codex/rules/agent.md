---
paths:
  - 'agent/**'
---

# GitOps agent

- Idempotent loop: fetch, compare, apply only what changed, health-check, keep the old version on
  failure, alert, remember the failing commit.
- Decrypted secrets only in `/run` (tmpfs); never logged.
- `set -euo pipefail`; shellcheck clean.
