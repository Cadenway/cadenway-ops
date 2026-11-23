# Fetch and validation

1. Fetch the managed references into a bare mirror and check the edge's running workloads.
2. Per environment, skip a commit already marked as failed. For an applied commit, compare real
   workload health, counts and configuration to the saved expectations. If they differ, repair
   the applied configuration without running migrations. Wait while the edge network is missing.
   Check out the commit and decrypt `secrets.sops.env` into `/run/cadenway/<env>/`, values
   single-quoted. Registry credentials go to a `DOCKER_CONFIG` under `/run`.
3. Refuse a commit that leaves a variable unset (versions excepted), or a definition that declares
   `DATABASE_URL` without its `<NAME>_SERVICE_MIGRATION_DATABASE_URL` secret; validate, pull and
   start the infrastructure.
