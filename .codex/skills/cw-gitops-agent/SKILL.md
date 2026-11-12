---
name: cw-gitops-agent
description: "What the agent on the VPS does on each run and how it rolls out, verifies and keeps the old version on failure. Load it before changing the agent."
---

# GitOps agent

`agent/cadenway-agent.sh`, run every minute by `cadenway-agent.timer`; configuration in
`/etc/cadenway/agent.env`, one or several environments per host (`CADENWAY_ENVIRONMENTS`). It takes
`/run/lock/cadenway-agent.lock` first (a restore holds it too) and cleans `/run/cadenway` on exit.

1. Fetch `main` into a bare mirror (a failed fetch fails the unit); apply `compose/edge.yaml` when the
   commit changed.
2. Per environment, skip a commit already applied or already failed; wait while its edge network is
   missing; check the commit out in the environment's worktree (recreated if broken) and decrypt
   `secrets.sops.env` into `/run/cadenway/<env>/`, values single-quoted. Registry credentials go to a
   `DOCKER_CONFIG` under `/run`.
3. Refuse a commit that leaves a variable unset (versions excepted); validate, pull and start the
   infrastructure.
4. For each deployable with a version: skip when its fingerprint (Compose hash + mounted config
   contents) is the applied one and every container runs it healthy; otherwise pull, migrate in a
   one-off container (`node dist/migrate.js` when present), start the new instance beside the old one,
   wait up to 60 s for `healthy`, remove the old one. An unhealthy first container is removed.
5. Outcome: **applied**; **failed** (desired state wrong: kept old instances, worktree back to the
   applied commit, never retried); **retrying** (exit 75: registry, network, start-up; every tick,
   notified once). Notifications carry environment, commit, duration, result; the webhook URL never
   appears in a process argument.

`agent/tests/e2e.sh` covers each of these against a real Docker daemon (CI job "GitOps agent and
backups end to end").
