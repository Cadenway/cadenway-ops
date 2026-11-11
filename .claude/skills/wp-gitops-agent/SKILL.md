---
name: wp-gitops-agent
description: "What the agent on the VPS does on each run and how it rolls out, verifies and keeps the old version on failure. Load it before changing the agent."
---

# GitOps agent

1. `git fetch`; exit if the commit is unchanged.
2. Diff `versions.env` and `services/` with the last applied commit: list changed services.
3. Decrypt `secrets.sops.env` into `/run/waypoint/`.
4. For each changed service: `pull`, run migrations in a one-off container, start the new instance
   beside the old one, wait up to 60 s for `healthy`, stop the old one.
5. Failure: keep the old instance, record the commit as failed, alert; do not retry that commit.
6. Notify: service, version, commit, duration, result.
