# Fetch and validation

1. Fetch `main` into a bare mirror (a failed fetch fails the unit); apply `compose/edge.yaml` when the
   commit changed.
2. Per environment, skip a commit already applied or already failed; wait while its edge network is
   missing; check the commit out in the environment's worktree (recreated if broken) and decrypt
   `secrets.sops.env` into `/run/cadenway/<env>/`, values single-quoted. Registry credentials go to a
   `DOCKER_CONFIG` under `/run`.
3. Refuse a commit that leaves a variable unset (versions excepted), or a definition that declares
   `DATABASE_URL` without its `<NAME>_SERVICE_MIGRATION_DATABASE_URL` secret; validate, pull and
   start the infrastructure.
