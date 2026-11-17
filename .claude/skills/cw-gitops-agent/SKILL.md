---
name: cw-gitops-agent
description: "Change the VPS GitOps fetch, environment validation, rollout, health checks or recovery."
---

# GitOps agent

`agent/cadenway-agent.sh`, run every minute by `cadenway-agent.timer`; configuration in
`/etc/cadenway/agent.env`, one or several environments per host (`CADENWAY_ENVIRONMENTS`). It takes
`/run/lock/cadenway-agent.lock` first (a restore holds it too) and cleans `/run/cadenway` on exit.

- Read [fetch and validation](references/fetch-and-validation.md) for locks between runs,
  worktrees, environment preparation and infrastructure.
- Read [rollout and recovery](references/rollout-and-recovery.md) for fingerprinting, migrations,
  health checks, retry and notifications.

`agent/tests/e2e.sh` covers each of these against a real Docker daemon (CI job "GitOps agent and
backups end to end").
