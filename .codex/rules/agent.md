---
paths:
  - 'agent/**'
---

# GitOps agent

Follow `cw-gitops-agent` for the idempotent rollout and recovery sequence. Keep decrypted secrets
in `/run` (tmpfs) and out of logs.
Use `set -euo pipefail` and pass ShellCheck.

## Review example

For example, when a candidate container fails its health check, verify that the previous version
keeps serving and that the failure is visible. Exercise this in the agent's end-to-end test when
changing the rollout path. If a change affects stored data, use the deployment and database guides
to check rollback compatibility and the restore procedure.
