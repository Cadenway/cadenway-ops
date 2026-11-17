# Rollout and recovery

4. For each deployable with a version: skip when its fingerprint (Compose hash + mounted config
   contents) is the applied one and every container runs it healthy; otherwise pull, migrate in a
   one-off container (`node dist/migrate.js` when present), given the migrator URL by the agent
   (`-e MIGRATION_DATABASE_URL`, read from the environment of that command), start the new instance
   beside the old one, wait up to 60 s for `healthy`, remove the old one. An unhealthy first
   container is removed. The agent reaches a host only through `ansible/playbooks/setup.yml`.
5. Outcome: **applied**; **failed** (desired state wrong: kept old instances, worktree back to the
   applied commit, never retried); **retrying** (exit 75: registry, network, start-up; every tick,
   notified once). Notifications carry environment, commit, duration, result; the webhook URL never
   appears in a process argument.
